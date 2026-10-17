require "test_helper"

# 17 Oct 2026: a step-3 save on a "complete" brief whose other steps had gaps was refused with a list
# that named no step, and read as a broken Save button. The refusal now names each step, and the page
# shows the open-problems card with a link per step.
class BriefKeepCompleteRefusalTest < ActionDispatch::IntegrationTest
  test "a refused save on a complete brief names the step of each gap and links to it" do
    job = briefed_job(golongan: 2, package: 2, complete: true, test_case: false)
    assert job.reload.brief_complete?
    job.activities.last(job.activities.size - 3).each(&:destroy!) # a gap in step 2, behind the brief's back
    sign_in_as staff_user("hr_pic")
    patch staff_job_brief_step_path(job, 3), params: { brief: { salary_min: "8.000.000", salary_max: "11.000.000", work_arrangement: "onsite" } }
    assert_response :unprocessable_content
    assert_includes response.body, "Step 2 (Activities &amp; 90-day target): There are 3 activities"
    assert_select "#brief-problems a[href*='/brief/2']", minimum: 1
  end
end
