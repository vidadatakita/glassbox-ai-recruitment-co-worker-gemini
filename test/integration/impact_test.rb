require "test_helper"

# AI Builder Cup "before / after": the Impact summary measures the user's own jobs; the BEFORE side
# is the client's figure from Settings and reads "not entered" until entered.
class ImpactTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    @job = technical_test_job(open_gate: false)
    @hr = staff_user("hr_pic")
    @a, = applicant!(@job)
    @b, = applicant!(@job)
    JobApplication.where(id: [@a.id, @b.id]).update_all(created_at: 3.hours.ago) # applied 3 hours before the choices
  end

  def rec(participation, advice)
    StageRecommendation.create!(participation:, requested_by: @hr, status: "ready", advice:, ai_score: 70, model_id: "uji",
                                prompt_version: "uji", created_at: Time.current, reasons: {})
  end

  test "the figures count what they say: first answer, reasoned choices, agreement with the AI" do
    rec(s1_of(@a), "lanjut")
    Progression::Choose.call(participation: s1_of(@a), actor: @hr, choice: "ikut_ai", seen_recommendation_id: StageRecommendation.last.id)
    rec(s1_of(@b), "lanjut")
    Progression::Choose.call(participation: s1_of(@b), actor: @hr, choice: "tidak_lanjut", note: "Kurang pengalaman.", seen_recommendation_id: StageRecommendation.last.id)

    impact = Impact.new(Job.where(id: @job.id))
    assert_equal 2, impact.applications
    assert_in_delta 3.0, impact.hours_to_answer.value, 0.1
    assert_equal [100, 2], [impact.reasoned_pct.value, impact.reasoned_pct.count]
    assert_equal [50, 2], [impact.agreement_pct.value, impact.agreement_pct.count]
    assert_nil impact.agreement_flag, "no flag under 20 choices"
  end

  test "the page shows 'not entered' until the client's figure is entered, and counts only the user's jobs" do
    sign_in_as @hr
    get staff_impact_path
    assert_response :success
    assert_includes response.body, "not entered"
    assert_includes response.body, "2 applications"

    Portal::UpdateSetting.call(key: "baseline_hours_to_answer", value: "72", actor: staff_user("admin"))
    get staff_impact_path
    assert_includes response.body, "72 hours"
    assert_raises(Portal::UpdateSetting::Invalid) { Portal::UpdateSetting.call(key: "baseline_reasoned_pct", value: "120", actor: staff_user("admin")) }
  end

  test "each matrix row opens to its vacancies, linking to the feature page that holds the records" do
    sign_in_as @hr
    get staff_impact_path
    assert_select "details.impact-row", count: 5
    assert_select "details#impact-hours a[href='#{staff_job_screening_report_path(@job)}']", text: /Screening report/
    # The HR Admin cannot open the reviewer's screening review, so the who-read rows point to the report.
    assert_select "details#impact-read a[href='#{staff_job_screening_review_path(@job)}']", count: 0
    assert_select "details#impact-read a[href='#{staff_job_screening_report_path(@job)}']"
    assert_select "details#impact-read td", text: @job.title

    sign_in_as staff_user("reviewer")
    get staff_impact_path
    assert_select "details#impact-read a[href='#{staff_job_screening_review_path(@job)}']"
  end

  test "the change is computed only when both sides exist, and says which way it went" do
    rec(s1_of(@a), "lanjut")
    Progression::Choose.call(participation: s1_of(@a), actor: @hr, choice: "ikut_ai", seen_recommendation_id: StageRecommendation.last.id)
    sign_in_as @hr
    get staff_impact_path
    assert_select "details#impact-hours .impact-row__change .impact-empty", text: "-"
    assert_select "details#impact-hours .impact-chip", { count: 0 }, "no result chip while one side is missing"

    Portal::UpdateSetting.call(key: "baseline_hours_to_answer", value: "72", actor: staff_user("admin"))
    get staff_impact_path
    assert_select "details#impact-hours .impact-chip--good", text: "96% faster" # 72 h before, 3 h measured
  end
end
