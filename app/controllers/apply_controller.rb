# Three-step application with the competency test (Vida, 17 Oct 2026), BESIDE the two-step form
# (LamarController): used only when the vacancy has an approved question bank. Step 1 personal
# details, knockout questions and consent (opens the draft), step 2 the CV, step 3 the test (one
# timer, answers saved as typed), then Submit. Steps 2-3 are reached by the secret in the link.
# The window is checked on every request and again inside SubmitApplication's lock.
class ApplyController < CandidateController
  LIMITS = Glassbox::Settings::RATE_LIMITS
  rate_limit to: LIMITS[:lamar_per_ip][:to], within: LIMITS[:lamar_per_ip][:within].seconds,
             only: %i[create save_cv submit], name: "apply-ip",
             with: -> { render "lamar/too_many", status: :too_many_requests }

  before_action :load_job
  before_action :require_open_bank_window
  before_action :load_draft, except: %i[new create]

  def new
    @answers = {}
    @values = {}
    load_consent_shown
  end

  def create
    result = ApplicationDrafts::Start.call(job: @job, params: person_params, channel_code: params[:ch])
    return render("lamar/not_eligible") if result.knocked_out
    return redirect_to(apply_cv_path(@job.public_code, result.secret)) if result.ok?

    @errors = result.field_errors.values
    @field_errors = result.field_errors
    @answers = person_params[:knockout]
    @values = person_params.except(:knockout, :consent_token)
    load_consent_shown
    render :new, status: :unprocessable_entity
  rescue ApplicationDrafts::Start::ConsentUnverifiable
    @answers = person_params[:knockout]
    @values = person_params.except(:knockout, :consent_token)
    @errors = ["The terms for the use of your data have changed. Please read and agree to the latest terms below."]
    @field_errors = { consent: @errors.first }
    load_consent_shown
    render :new, status: :unprocessable_entity
  end

  def cv; end

  def save_cv
    @cv_error = ApplicationDrafts::SaveCv.call(@draft, params.dig(:lamaran, :cv))
    return render(:cv, status: :unprocessable_entity) if @cv_error

    redirect_to apply_test_path(@job.public_code, params[:secret])
  end

  def test
    return redirect_to(apply_cv_path(@job.public_code, params[:secret])) unless @draft.cv.attached?
  end

  def start_test
    return redirect_to(apply_cv_path(@job.public_code, params[:secret])) unless @draft.cv.attached?

    ApplicationDrafts::StartTest.call(@draft)
    redirect_to apply_test_path(@job.public_code, params[:secret])
  end

  # Autosave (fetch, answers JSON-free as form fields) and the form's "Save answers" button.
  def save_answers
    result = ApplicationDrafts::SaveAnswers.call(@draft, answer_params)
    if request.xhr? || request.format.json?
      return render(json: { saved: result.saved, error: result.error }, status: result.error ? :unprocessable_entity : :ok)
    end

    redirect_to apply_test_path(@job.public_code, params[:secret]), **(result.error ? { alert: result.error } : { notice: "Answers saved." })
  end

  def submit
    ApplicationDrafts::SaveAnswers.call(@draft, answer_params) if answer_params.present? && !@draft.time_over?
    result = ApplicationDrafts::Submit.call(draft: @draft)
    if result.errors.any?
      @errors = result.errors
      return render(:test, status: :unprocessable_entity)
    end

    @token = result.token
    @application = result.application
    return render("lamar/not_eligible") if result.knocked_out

    MailDelivery.deliver!(@application, "application_ack") { CandidateMailer.application_ack(@application, @token) }
    # Slice C: the written answers get their AI suggestion right after Submit, in the background.
    @draft.update_columns(ai_status: "pending")
    BankAnswerAiRateJob.perform_later(@draft.id)
    render "lamar/sent"
  rescue Portal::SubmitApplication::Closed
    @window = ApplicationWindow.new(@job)
    render "lamar/closed", status: :gone
  end

  private

  def load_job
    @job = Job.find_by(public_code: params[:code]) or render("candidate_status/invalid", status: :not_found)
  end

  # Only a vacancy with an approved bank uses this form; any other goes to the two-step form. A closed
  # portal answers "closed" for every step, as in the two-step form.
  def require_open_bank_window
    return if performed?
    return redirect_to(lamar_path(@job.public_code, ch: params[:ch])) unless QuestionBank.current_for(@job)

    @window = ApplicationWindow.new(@job)
    render("lamar/closed", status: (request.get? ? :ok : :gone)) unless @window.open?
  end

  def load_draft
    return if performed?

    @draft = ApplicationDraft.find_by_secret(@job, params[:secret])
    return render_invalid_link if @draft.nil?

    render "apply/already_sent" if @draft.submitted?
  end

  def load_consent_shown
    @consent = ConsentTemplate.in_force(company: @job.client_company)
    @retention_days = SystemSetting.retention_days(company: @job.client_company)
    @consent_token = Portal::SubmitApplication.sign_consent(@consent, @retention_days) if @consent && @retention_days
  end

  def person_params
    @person_params ||= begin
      knockout = params.fetch(:knockout, {}).permit!.to_h.slice(*@job.knockout_questions.map { |q| q.id.to_s })
      params.fetch(:lamaran, {}).permit(:name, :email, :phone, :consent, :consent_token, :expected_salary_min,
                                        :expected_salary_max, :domicile_city).to_h.symbolize_keys.merge(knockout:)
    end
  end

  def answer_params = params.fetch(:answers, {}).permit!.to_h
end
