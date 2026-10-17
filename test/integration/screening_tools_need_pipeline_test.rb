require "test_helper"

# Vacancy page, 17 Oct 2026: the CV screening tools (Calibration, Review before AI, Screening review,
# Start screening) appear only once the pipeline holds a CV; an empty pipeline shows a note instead.
class ScreeningToolsNeedPipelineTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    Rails.cache.clear
    @job = screening_job
    sign_in_as staff_user("superadmin")
  end

  def tool_paths
    [staff_job_screening_calibration_path(@job), staff_job_ai_releases_path(@job),
     staff_job_screening_review_path(@job), staff_job_screening_start_path(@job)]
  end

  def links_and_forms
    get staff_job_path(@job)
    assert_response :success
    css_select("#screening a, #screening form").map { |e| e["href"] || e["action"] }.compact
  end

  test "an empty pipeline shows the note and none of the four tools" do
    assert ScreeningBoard.new(@job).participations.empty?
    found = links_and_forms
    assert_select "#screening .screening-actions__empty", 1
    tool_paths.each { |path| refute_includes found, path }
    # The report and the fairness check are greyed out, not links, until a CV arrives.
    refute_includes css_select("a").map { |e| e["href"] }, staff_job_screening_report_path(@job)
    refute_includes css_select("a").map { |e| e["href"] }, staff_job_fairness_check_path(@job)
    assert_select ".link-waiting[aria-disabled='true']", minimum: 1
  end

  test "control: once a CV is in the pipeline the tools are back" do
    apply_with_cv!(@job)
    refute ScreeningBoard.new(@job).participations.empty?
    found = links_and_forms
    assert_select "#screening .screening-actions__empty", 0
    assert_includes found, staff_job_screening_calibration_path(@job)
    assert_includes found, staff_job_screening_review_path(@job)
    assert_select "a[href='#{staff_job_screening_report_path(@job)}']", 1
    assert_select ".link-waiting", 0
  end
end
