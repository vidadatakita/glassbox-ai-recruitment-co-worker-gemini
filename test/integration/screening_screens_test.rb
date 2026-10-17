require "test_helper"

# Feature 06 screens: the job page box ("AI screening is off", "Screening failed"), Antrean Kerja, Review
# Screening (screen 8), Kalibrasi, and the CV text page. Roles from blueprint §1.2; house form
# rules from §5.3, asserted on the rendered HTML.
class ScreeningScreensTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    Rails.cache.clear
    @job = screening_job
    @fake = FakeGemini.new
  end

  # Nokogiri, like a browser, silently un-nests forms, so count the raw tags too.
  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    doc.css("form").each { |form| assert_empty form.css("form") }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
  end

  test "no API key: job page and Antrean Kerja say the AI screening is off" do
    Screening::Config.stub(:api_key, nil) do
      apply_with_cv!(@job)
      sign_in_as staff_user("consultant")
      get staff_job_path(@job)
      assert_response :success
      assert_includes response.body, ScreeningBoard::OFF_MESSAGE
      assert_includes response.body, "1 applications are waiting for screening"
      assert_select "form[action='#{staff_job_screening_start_path(@job)}']", 0, "no start button while the AI is off"
      assert_house_form_rules
      get staff_work_queue_path
      assert_includes response.body, ScreeningBoard::OFF_MESSAGE
      post staff_job_screening_start_path(@job)
      assert_redirected_to staff_job_path(@job)
      assert_equal ScreeningBoard::OFF_MESSAGE, flash[:alert]
    end
  end

  test "a failed screening shows 'Screening failed' with its reason on the job page and in Antrean Kerja" do
    with_ai(@fake) do
      @fake.push(refusal_message(category: "bio"))
      apply_with_cv!(@job)
      screen_and_release!
      sign_in_as staff_user("consultant")
      get staff_job_path(@job)
      assert_select "#screening", text: /Screening failed/
      assert_includes response.body, "The AI declined to assess this CV (bio)"
      assert_includes response.body, "No score was produced."
      assert_house_form_rules
      get staff_work_queue_path
      assert_select "#screening", text: /Screening failed/
      # Three-role model (17 Oct 2026): the HR admin is blind before the gate, so the row names the
      # candidate by number, never by name.
      assert_select "#screening", text: /Candidate 01/
      assert_select "#screening", text: /#{CANDIDATE_NAME}/, count: 0
    end
  end

  test "client users see S1 candidates as numbers in the screening box (rule 14); staff see names" do
    with_ai(@fake) do
      @fake.push(refusal_message)
      apply_with_cv!(@job)
      screen_and_release!
    end
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@job)
    assert_select "#screening", text: /Candidate 01/
    assert_select "#screening", text: /#{CANDIDATE_NAME}/, count: 0
  end

  test "Review Screening is the reviewer's screen; before calibration results show as 'Not yet calibrated' with no action" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job, wajib: "not_met")))
      apply_with_cv!(@job)
      screen_and_release!
    end
    sign_in_as staff_user("consultant")
    get staff_job_screening_review_path(@job)
    assert_redirected_to staff_jobs_path
    sign_in_as staff_user("reviewer")
    get staff_job_screening_review_path(@job)
    assert_response :success
    assert_includes response.body, "Not yet calibrated."
    assert_includes response.body, "not a final decision"
    assert_select "form[action^='/staff/screening_results/']", 0
    assert_house_form_rules
  end

  test "after calibration the reviewer confirms an elimination through the screen; the decision is recorded" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) do
      calibrate!(@job, @fake, release: true)
      @fake.push(gemini_message(criteria_for(@job, wajib: "not_met")))
      @participation = apply_with_cv!(@job, name: "Calon Ditinjau")
      screen_and_release!
    end
    sign_in_as staff_user("reviewer")
    get staff_job_screening_review_path(@job)
    result = @participation.screening_results.last
    assert_select "form[action='#{staff_screening_result_review_path(result)}'] button[name=commit][value='Save review']"
    assert_includes response.body, "AI elimination"
    refute_includes response.body, "gemini-3.8-flash", "no model name on screen (owner, 2026-10-11)"
    assert_includes response.body, "Assessed by the AI"
    assert_house_form_rules
    post staff_screening_result_review_path(result), params: { verdict: "confirm", note: "" }
    assert_redirected_to staff_job_screening_review_path(@job)
    assert_equal "eliminate", @participation.reload.current_decision.outcome
    follow_redirect!
    assert_select "td", text: "Uji reviewer"
  end

  test "the job's consultant, even with the reviewer role, is refused on the screen" do
    reviewer = staff_user("reviewer")
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) do
      calibrate!(@job, @fake, release: true)
      @fake.push(gemini_message(criteria_for(@job, wajib: "not_met")))
      @participation = apply_with_cv!(@job, name: "Calon Ditinjau")
      screen_and_release!
    end
    @job.update!(consultant: reviewer)
    sign_in_as reviewer
    get staff_job_screening_review_path(@job)
    assert_includes response.body, "cannot also review its screening"
    assert_select "form[action^='/staff/screening_results/']", 0
    post staff_screening_result_review_path(@participation.screening_results.last), params: { verdict: "confirm" }
    assert_equal "The reviewer cannot be the consultant of this vacancy.", flash[:alert]
    assert_nil @participation.reload.current_decision
  end

  test "calibration screen: the AI's answer stays hidden until the consultant has judged that CV" do
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    sign_in_as @job.consultant
    get staff_job_screening_calibration_path(@job)
    assert_response :success
    assert_select "#kalibrasi-#{@participation.id}", text: /Hidden until the HR Admin has judged/
    assert_select "#kalibrasi-#{@participation.id} form button[value='Save judgement']"
    assert_house_form_rules
    post staff_participation_calibration_path(@participation), params: { outcome: "pass" }
    follow_redirect!
    assert_select "#kalibrasi-#{@participation.id}", text: /Passed \(score 100,0\)/
    assert_select "#kalibrasi-#{@participation.id}", text: /Same/
  end

  test "CV unreadable: the consultant pastes the text through the screen" do
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, pdf: pdf_without_text)
      screen_and_release!
      sign_in_as @job.consultant
      get staff_job_path(@job)
      assert_select "#screening", text: /CV unreadable/
      assert_select "a[href='#{staff_participation_cv_text_path(@participation)}']"
      get staff_participation_cv_text_path(@participation)
      assert_house_form_rules
      post staff_participation_cv_text_path(@participation), params: { cv_text: "pendek" }
      assert_response :unprocessable_entity
      assert_includes response.body, "The CV text is too short"
      @fake.push(gemini_message(criteria_for(@job)))
      post staff_participation_cv_text_path(@participation), params: { cv_text: FIXTURE_CV }
      assert_redirected_to staff_job_path(@job, anchor: "screening")
      screen_and_release!
    end
    assert_equal "done", @participation.reload.screening_state
  end

  # D51 (feature 09): an application that arrives while the AI is off is now queued at once and
  # prepared for the reviewer (nothing is sent), so "Mulai screening" finds nothing new to queue for
  # it; the count in the notice is therefore not asserted as 1 any more.
  # Three-role model (17 Oct 2026): Start screening is an HR admin action; the HR manager (old owner
  # and reviewer) is the role refused.
  test "Start screening is an HR admin action; it queues what arrived while the AI was off" do
    Screening::Config.stub(:api_key, nil) { @participation = apply_with_cv!(@job) }
    with_ai(@fake) do
      %w[reviewer owner].each do |role|
        sign_in_as staff_user(role)
        get staff_job_path(@job)
        assert_select "form[action='#{staff_job_screening_start_path(@job)}']", 0, "#{role} is offered Start screening"
        post staff_job_screening_start_path(@job)
        assert_equal "You do not have access to this action.", flash[:alert], role
      end
      sign_in_as @job.consultant
      get staff_job_path(@job)
      assert_select "form[action='#{staff_job_screening_start_path(@job)}'] button[value='Start screening']"
      @fake.push(gemini_message(criteria_for(@job)))
      post staff_job_screening_start_path(@job)
      assert_match(/\d+ application\(s\) queued for screening/, flash[:notice])
      screen_and_release!
    end
    assert_equal "done", @participation.reload.screening_state
  end

  # End-to-end test, 16 Oct 2026: the public demo opens the HR owner, reviewer and owner doors, no
  # consultant, so a failed screening could not be retried there. Risks hunted: the retry missing
  # for a role, or sending again a CV that needs a manual check.
  # Three-role model (17 Oct 2026): retry is open to hr_admin, hr_manager and superadmin, i.e. every
  # role, so no role is refused any more; every old person is asserted on the allowed side.
  test "every role retries a failed screening; a manual-check row stays" do
    with_ai(@fake) do
      @fake.push(refusal_message(category: "bio"), refusal_message(category: "bio"))
      failed = apply_with_cv!(@job)
      manual = apply_with_cv!(@job, name: "Dewi Anggraini")
      screen_and_release!
      assert_equal %w[screening_failed screening_failed], [failed.reload, manual.reload].map(&:screening_state)
      manual.update_columns(screening_failure: "personal_data", screening_failure_detail: nil)
      retry_button = "form[action='#{staff_job_screening_retry_path(@job)}'] button[name=commit][value='Retry failed screening (1)']"

      [staff_user("owner"), @job.consultant, staff_user("reviewer")].each do |user|
        sign_in_as user
        get staff_job_path(@job)
        assert_select retry_button
      end
      assert_equal "screening_failed", failed.reload.screening_state, "showing the button retries nothing"

      sign_in_as staff_user("hr_pic")
      get staff_job_path(@job)
      assert_select retry_button
      assert_house_form_rules
      post staff_job_screening_retry_path(@job)
      assert_redirected_to staff_job_path(@job, anchor: "screening")
      assert_equal "1 failed screening(s) queued again. The result appears here when the AI has answered.", flash[:notice]
      assert_equal "queued", failed.reload.screening_state
      @fake.push(gemini_message(criteria_for(@job)))
      perform_enqueued_jobs
      assert_equal "done", failed.reload.screening_state
      assert_equal %w[screening_failed personal_data], [manual.reload.screening_state, manual.screening_failure], "a manual check needs a pasted text, not a retry"
    end
    assert_equal 3, @fake.requests.size, "two first attempts and one retry; the manual-check CV was not sent again"
  end
end
