require "test_helper"

# 17 Oct 2026 (Vida): after version 1 of the case is approved, step 5 shows it read-only with no Save
# and no reason error; the editor (reason first) opens only through "Create a new version".
class ApprovedCaseReadOnlyTest < ActionDispatch::IntegrationTest
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @job.update!(consultant: staff_user("consultant"))
    approved_test_case!(@job)
    sign_in_as staff_user("consultant")
  end

  test "an approved-only case renders read-only: no case Save, no reason field, a Create a new version link" do
    get staff_job_test_case_step_path(@job)
    assert_response :success
    assert_select "form[action$='/test_cases']", 0, "the case editor is hidden"
    assert_select "textarea[name='test_case[new_version_reason]']", 0
    refute_includes response.body, "reason for the new version is required"
    assert_select "a[href*='new_version=1']", text: /Create a new version/
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"
  end

  test "Create a new version opens the editor with the reason field before the case fields" do
    get staff_job_test_case_step_path(@job, new_version: 1)
    assert_select "form[action$='/test_cases']", 1
    body = response.body
    reason_at = body.index('name="test_case[new_version_reason]"')
    instructions_at = body.index('name="test_case[instructions]"')
    assert reason_at && instructions_at && reason_at < instructions_at, "the reason comes first"
  end

  test "a draft version keeps today's editor" do
    job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    job.update!(consultant: staff_user("consultant"))
    TestCases::SaveVersion.call(job:, actor: staff_user("consultant"), params: case_version_params(job))
    get staff_job_test_case_step_path(job)
    assert_select "form[action$='/test_cases']", 1
    assert_select "textarea[name='test_case[new_version_reason]']", 0
  end
end
