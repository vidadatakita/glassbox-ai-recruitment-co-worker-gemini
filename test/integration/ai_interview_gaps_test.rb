require "test_helper"

# AI interview gaps closed on 18 Oct 2026: the status page
# leads back into an open interview, the vacancy page counts interviews, and Start screening warns before
# it ends the open ones. Each with a control.
class AiInterviewGapsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    Rails.cache.clear
    @job = screening_job
    @job.activities.create!(position: 1, description: "Receive and shelve incoming goods", output: "Shelved stock", share_percent: 100)
  end

  def switch_on = switch_ai_interview_on(actor: staff_user("admin"))

  # The real two-step apply form with the interview on; returns the raw status token.
  def apply_with_interview
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    consent = Nokogiri::HTML(response.body).at_css("input[name='lamaran[consent_token]']")&.[]("value")
    with_env({ "AI_SCREENING_REVIEW" => "auto" }) do
      with_ai(FakeGemini.new) do
        post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
          lamaran: application_params(@job, cv: pdf_upload(pdf_with_text(FIXTURE_CV))).except(:knockout).merge(consent_token: consent) }
      end
    end
    response.location[%r{/status/([^/]+)/interview}, 1]
  end

  def vacancy_page_as_superadmin
    sign_in_as staff_user("superadmin")
    with_env({ "AI_SCREENING_REVIEW" => "auto" }) { with_ai(FakeGemini.new) { get staff_job_path(@job) } }
    assert_response :success
  end

  test "the status page offers the way back into an open interview; none once it has ended" do
    switch_on
    token = apply_with_interview
    assert token, "the apply form hands over to the interview"
    get candidate_status_path(token)
    assert_select "#ai-interview-card", 1
    assert_select "a[href='#{candidate_status_interview_path(token)}']", text: "Start the AI interview"

    Interviews::Finish.call(Interview.last, reason: "never_started", queue: false)
    get candidate_status_path(token)
    assert_select "#ai-interview-card", 0, "control: no link to a closed interview"
  end

  test "the vacancy page counts interviews and warns before Start screening ends the open ones" do
    switch_on
    apply_with_interview
    vacancy_page_as_superadmin
    assert_select "#ai-interviews", 1
    assert_select "#ai-interviews li", text: /1\s+not started yet/
    assert_select ".screening-actions__warning", text: /1 AI interview still open/

    Interviews::Finish.call(Interview.last, reason: "staff_started", queue: false)
    vacancy_page_as_superadmin
    assert_select ".screening-actions__warning", 0, "control: no warning once nothing is open"
    assert_select "#ai-interviews li.is-ended", text: /1\s+screening started by staff/
  end

  test "control: a vacancy without interviews shows no interview line" do
    apply_with_cv!(@job)
    vacancy_page_as_superadmin
    assert_select "#ai-interviews", 0
  end
end
