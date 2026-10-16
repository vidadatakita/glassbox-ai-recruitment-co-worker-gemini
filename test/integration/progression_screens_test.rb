require "test_helper"

# AI Builder Cup step 06 on the applicant page: the HR PIC sees the panel and the three choices,
# chooses, scores Interview 1; other roles read only and are refused by the controller.
class ProgressionScreensTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    Rails.cache.clear
    @job = technical_test_job(open_gate: false)
    @application, = applicant!(@job)
    @s1 = s1_of(@application)
  end

  def house_rules!
    doc = Nokogiri::HTML(response.body)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form" }
    assert_empty doc.css("button[disabled], [data-disable-with]"), "disabled submit"
    doc
  end

  test "the HR PIC chooses Lanjut, the candidate enters Interview 1, and the HR PIC scores it" do
    sign_in_as staff_user("hr_pic")
    get staff_application_path(@application)
    doc = house_rules!
    assert doc.at_css("button[name=choice][value=lanjut]")
    assert doc.at_css("button[name=choice][value=tidak_lanjut]")
    assert_nil doc.at_css("button[name=choice][value=ikut_ai]"), "no AI choice without a ready recommendation"

    post staff_participation_choice_path(@s1), params: { choice: "tidak_lanjut", note: "" }
    follow_redirect!
    assert_includes response.body, "A reason is required for every Do not continue."
    assert_includes response.body, "is-invalid"

    post staff_participation_choice_path(@s1), params: { choice: "lanjut", note: "" }
    follow_redirect!
    assert_includes response.body, "The candidate enters the next stage"
    s3 = @application.participations.joins(:stage).find_by!(stages: { code: "S3" })
    doc = house_rules!
    assert doc.at_css("form[action='#{staff_participation_interview_path(s3)}']"), "the Interview 1 scorecard is offered"

    ratings = @job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, "4"] }
    Screening::Config.stub(:enabled?, false) do
      post staff_participation_interview_path(s3), params: { attendance: "attended", ratings:, note: "Jelas dan runtut." }
    end
    follow_redirect!
    assert_includes response.body, "Interview scoring saved."
    assert_includes response.body, "The AI feature is off", "without an AI provider the panel says so"
    assert_nil Nokogiri::HTML(response.body).at_css("form[action$='/ai-advice']"), "and offers no AI button"
    assert_equal 0, StageRecommendation.count, "and no failed rows pile up"
    assert_equal Scoring::StageScore.from_ratings(ratings.values.map(&:to_i)), s3.reload.current_score
  end

  test "a consultant reads the panel but cannot choose" do
    sign_in_as staff_user("consultant")
    get staff_application_path(@application)
    assert_nil Nokogiri::HTML(response.body).at_css("button[name=choice]")
    post staff_participation_choice_path(@s1), params: { choice: "lanjut" }
    assert_nil @s1.reload.progression_choice
  end
end
