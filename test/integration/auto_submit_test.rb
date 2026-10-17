require "test_helper"

# Vida 18 Oct 2026: an applicant who closes the tab before the deadline is submitted automatically.
# ApplicationDrafts::AutoSubmit sends a started test once the answer deadline (+ grace) has passed,
# through the same Submit + AfterSubmit as the Send button; it leaves every other draft alone.
class AutoSubmitTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include BankFlowHelpers
  include ActiveJob::TestHelper

  setup { ActionMailer::Base.deliveries.clear }

  # Steps 1-3 of the form, answers saved, Send never pressed (the tab was closed).
  def started_draft!(email, start: true)
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name: "Away #{email}", email:, phone: "081234567890", consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    draft = ApplicationDraft.find_by_secret(@job, secret)
    return draft unless start

    post apply_test_start_path(@job.public_code, secret)
    draft.reload
    answers = draft.questions.to_h { |q| [q.id.to_s, q.multiple_choice? ? "0" : "My saved answer."] }
    assert_nil ApplicationDrafts::SaveAnswers.call(draft, answers).error
    draft.reload
  end

  def past_deadline(draft) = draft.answer_deadline + 1.second

  test "a started test past its deadline is sent with its saved answers, the e-mail and the AI rating" do
    draft = started_draft!("away@uji.example")
    at = past_deadline(draft)

    result = nil
    assert_enqueued_with(job: BankAnswerAiRateJob, args: [draft.id]) { result = ApplicationDrafts::AutoSubmit.call(now: at) }
    assert_equal [1, 0, 0], [result.submitted, result.skipped, result.failed]
    draft.reload
    assert draft.submitted?
    assert_equal at.to_i, draft.submitted_at.to_i
    assert_equal "pending", draft.ai_status
    application = draft.job_application
    assert_equal "away@uji.example", application.candidate.email
    assert_equal 1, MailDelivery.where(job_application: application, kind: "application_ack", status: "sent").count
    assert_equal ["away@uji.example"], ActionMailer::Base.deliveries.flat_map(&:to)
    assert draft.answers.select { |a| a.bank_question.multiple_choice? }.all?(&:correct), "the saved choices were scored"

    again = ApplicationDrafts::AutoSubmit.call(now: at + 5.minutes)
    assert_equal [0, 0, 0], [again.submitted, again.skipped, again.failed], "a sent draft is not selected again"
  end

  test "before the deadline plus grace nothing is sent" do
    draft = started_draft!("early@uji.example")
    result = ApplicationDrafts::AutoSubmit.call(now: draft.answer_deadline - 1.second)
    assert_equal [0, 0, 0], [result.submitted, result.skipped, result.failed]
    refute draft.reload.submitted?
    assert_operator draft.answer_deadline, :>, draft.test_due_at, "control: the grace is part of the deadline"
    refute ApplicationDrafts::AutoSubmit.call(now: draft.test_due_at + 1.second).submitted.positive?, "inside the grace"
  end

  test "a draft whose test never started is never sent" do
    draft = started_draft!("nostart@uji.example", start: false)
    result = ApplicationDrafts::AutoSubmit.call(now: 2.days.from_now)
    assert_equal 0, result.submitted
    refute draft.reload.submitted?
    assert_equal 0, ActionMailer::Base.deliveries.size
  end

  test "a draft without a CV is skipped and left as it is" do
    draft = started_draft!("nocv@uji.example")
    draft.cv.detach
    result = ApplicationDrafts::AutoSubmit.call(now: past_deadline(draft))
    assert_equal [0, 1, 0], [result.submitted, result.skipped, result.failed]
    refute draft.reload.submitted?
  end

  test "a test started while the portal was open is still sent after the portal closed" do
    draft = started_draft!("closed@uji.example")
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    refute ApplicationWindow.new(@job).open?, "control: the portal is closed"
    result = ApplicationDrafts::AutoSubmit.call(now: past_deadline(draft))
    assert_equal [1, 0, 0], [result.submitted, result.skipped, result.failed]
    assert draft.reload.submitted?
    assert_equal ["closed@uji.example"], ActionMailer::Base.deliveries.flat_map(&:to)
  end

  test "when the first stage is closed the draft is skipped, logged, and left unsent" do
    draft = started_draft!("stage@uji.example")
    log = StringIO.new
    old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    @job.stages.where.not(code: "RC").order(:code).first.update_columns(status: "closed")
    assert ApplicationWindow.new(@job).first_stage_closed?, "control: the first stage is closed"
    result = ApplicationDrafts::AutoSubmit.call(now: past_deadline(draft))
    Rails.logger = old_logger
    assert_equal [0, 1, 0], [result.submitted, result.skipped, result.failed]
    refute draft.reload.submitted?
    assert_includes log.string, "[auto_submit] draft #{draft.id} not submitted: the first stage (CV screening) is closed"
    assert_equal 0, ActionMailer::Base.deliveries.size
  end

  test "a refusal by Submit is counted as failed and logged with the draft id only" do
    draft = started_draft!("refused@uji.example")
    refusal = ApplicationDrafts::Submit::Result.new(nil, nil, ["Invented refusal."], false, {})
    log = StringIO.new
    old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    result = ApplicationDrafts::Submit.stub(:call, refusal) { ApplicationDrafts::AutoSubmit.call(now: past_deadline(draft)) }
    Rails.logger = old_logger
    assert_equal [0, 0, 1], [result.submitted, result.skipped, result.failed]
    assert_includes log.string, "[auto_submit] draft #{draft.id} not submitted: Invented refusal."
    refute_includes log.string, "refused@uji.example", "no personal data in the log"
  end

  test "a live Send racing the sweep makes one application and one e-mail" do
    draft = started_draft!("race@uji.example")
    # Loaded by the sweep, CV included, before the applicant pressed Send: the CV check passes on the
    # stale copy, so only Submit's row lock can stop a second application.
    stale = ApplicationDraft.find(draft.id)
    assert stale.cv.attached?
    at = past_deadline(draft)
    sent = ApplicationDrafts::Submit.call(draft:, now: at)
    ApplicationDrafts::AfterSubmit.call(draft:, application: sent.application, token: sent.token)

    assert_equal :skipped, ApplicationDrafts::AutoSubmit.submit_one(stale, now: at)
    assert_equal 1, JobApplication.joins(:candidate).where(candidates: { email: "race@uji.example" }).count
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "the job runs the sweep and returns the counts" do
    draft = started_draft!("job@uji.example")
    travel_to(past_deadline(draft)) do
      result = ApplicationDraftAutoSubmitJob.perform_now
      assert_equal 1, result.submitted
    end
    assert draft.reload.submitted?
  end
end
