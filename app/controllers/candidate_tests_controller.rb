# The technical test inside the apply flow (D60 slice 3; plan Part 1 §b, §d). Reached only through
# the candidate's private status link; a tampered, revoked or withdrawn link gets the one "Link tidak
# berlaku" page, exactly like the status page.
#
#   GET  show       the start page (before the clock: duration, laptop advice, "Start test"), the
#                   running page (countdown from the server's due_at, the case-file link, the answer
#                   upload), the sent page, or the "Not taken" page
#   POST start      TechnicalTests::Start (idempotent; the server's clock)
#   GET  case_file  the case file, only after start, only with a short-lived signed key minted on
#                   the running page (10 minutes), as an attachment with nosniff
#   POST answer     TechnicalTests::SubmitAnswer (one answer, content-checked, until due_at + grace)
#
# Every page load first runs TechnicalTests::Expire, so a test past its deadline reads "Not
# taken" and is recorded as a no-show even if the recurring job has not run.
# Forms run without Turbo (the candidate layout loads none); no button is ever disabled.
class CandidateTestsController < CandidateController
  LIMITS = Glassbox::Settings::RATE_LIMITS
  CASE_FILE_KEY_LIFETIME = 10.minutes

  rate_limit to: LIMITS[:test_start_per_link][:to], within: LIMITS[:test_start_per_link][:within].seconds,
             only: :start, name: "test-start", by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_test_path(params[:token]), alert: "Too many attempts. Try again in a few minutes." }
  rate_limit to: LIMITS[:test_answer_per_link][:to], within: LIMITS[:test_answer_per_link][:within].seconds,
             only: :answer, name: "test-answer", by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_test_path(params[:token]), alert: "Too many upload attempts. Try again in a few minutes." }
  rate_limit to: LIMITS[:test_case_file_per_link][:to], within: LIMITS[:test_case_file_per_link][:within].seconds,
             only: :case_file, name: "test-case-file", by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_test_path(params[:token]), alert: "Too many downloads. Try again in a few minutes." }

  before_action :load_link
  before_action :refuse_after_withdrawal

  def show
    TechnicalTests::Expire.call(@application)
    @test = TechnicalTests::Status.new(@application.reload)
    return render_invalid_link unless @test.applies?

    @case_file_key = case_file_key(@test.attempt) if @test.state == :running
  end

  def start
    TechnicalTests::Start.call(application: @application)
    redirect_to candidate_status_test_path(params[:token])
  rescue TechnicalTests::Start::Refused => e
    redirect_to candidate_status_test_path(params[:token]), alert: e.message
  end

  def case_file
    attempt = TechnicalTests::Status.new(@application).attempt
    return render_invalid_link unless attempt && valid_case_file_key?(attempt)

    version = attempt.test_case
    file = version.case_file
    return render_invalid_link unless file.attached? && file.blob_id == version.case_file_blob_id

    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data file.download, filename: "technical-test-case-file.#{version.case_file_kind}",
                             type: file.content_type, disposition: "attachment"
  end

  def answer
    TechnicalTests::SubmitAnswer.call(application: @application, file: params[:jawaban], url: params[:repo_url])
    TechnicalTests::Notices.receipt(@application)
    redirect_to candidate_status_test_path(params[:token]), notice: "We have received your answer."
  rescue TechnicalTests::SubmitAnswer::Refused => e
    redirect_to candidate_status_test_path(params[:token]), alert: e.message
  end

  private

  def load_link
    @link = OneTimeLink.live("candidate_status", params[:token])
    @application = @link&.subject
    render_invalid_link if @application.nil?
  end

  def refuse_after_withdrawal
    render_invalid_link if @application.consent_withdrawn_at.present?
  end

  def key_verifier = Rails.application.message_verifier(:test_case_file)

  # Bound to the attempt AND the status link, so a key copied from one candidate's page opens
  # nothing under another candidate's link.
  def case_file_key(attempt)
    key_verifier.generate({ "attempt" => attempt.id, "link" => @link.id }, expires_in: CASE_FILE_KEY_LIFETIME)
  end

  def valid_case_file_key?(attempt)
    data = key_verifier.verified(params[:k].to_s)
    data.is_a?(Hash) && data["attempt"] == attempt.id && data["link"] == @link.id
  end
end
