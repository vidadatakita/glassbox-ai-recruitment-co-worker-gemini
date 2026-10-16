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
      assert_select "#screening", text: /#{CANDIDATE_NAME}/
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
    assert_includes response.body, "cannot be the reviewer"
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
    assert_select "#kalibrasi-#{@participation.id}", text: /Hidden until the consultant has judged/
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
  test "Start screening is a consultant action; it queues what arrived while the AI was off" do
    Screening::Config.stub(:api_key, nil) { @participation = apply_with_cv!(@job) }
    with_ai(@fake) do
      sign_in_as staff_user("hr_pic")
      post staff_job_screening_start_path(@job)
      assert_equal "You do not have access to this action.", flash[:alert]
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
end
