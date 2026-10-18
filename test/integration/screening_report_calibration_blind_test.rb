require "test_helper"
require_relative "../engine/screening_report/engine08_support"

# 18 Oct 2026 (Vida): the screening report and its Excel showed the AI's score on unjudged calibration
# CVs to the very people who judge them. Now the report follows Screening::CalibrationBlind like every
# other screen: the judges (the vacancy's consultant, the superadmin) see "Hidden" until that CV is
# judged; the HR Manager, who does not judge calibration, still sees the score (control); and once the
# consultant has judged, the judges see it too (control).
class ScreeningReportCalibrationBlindTest < ActionDispatch::IntegrationTest
  include Engine08Support

  setup do
    @job, s1, s2 = e8_job
    @application, @p1, _p2 = e8_applicant(@job, s1, s2, name: "Kirana Uji")
    e8_result(@p1, score: 81)
    @judges = [@job.consultant, staff_user("superadmin")]
  end

  def detail_as(user)
    sign_in_as user
    get staff_job_screening_report_candidate_path(@job, @application.id)
    assert_response :success
    response.body
  end

  test "an unjudged calibration CV is hidden from the judges: board (list and Excel) and detail page" do
    assert Screening::Calibration.new(@job).member?(@p1), "fixture: the CV is a calibration CV"
    @judges.each do |judge|
      row = e8_board(@job, judge).row_for(@application.id)
      assert row.blinded, "#{judge.role} is blinded"
      assert_nil row.ai_score, "#{judge.role}: no AI score reaches the list, the detail page or the Excel"
      assert_nil row.label_key, "#{judge.role}: no AI label either"
      body = detail_as(judge)
      assert_includes body, "until you judge this calibration CV"
      refute_includes body, "score 81 of 100"
    end
  end

  test "control: the HR Manager does not judge calibration and sees the score" do
    manager = staff_user("reviewer")
    row = e8_board(@job, manager).row_for(@application.id)
    refute row.blinded
    assert_equal 81, row.ai_score.to_i
    assert_includes detail_as(manager), "score 81 of 100"
  end

  test "control: once the consultant has judged the CV, the judges see the score" do
    e8_judge_calibration!(@job)
    @judges.each do |judge|
      refute e8_board(@job, judge).row_for(@application.id).blinded, "#{judge.role} after the judgement"
      assert_includes detail_as(judge), "score 81 of 100"
    end
  end
end
