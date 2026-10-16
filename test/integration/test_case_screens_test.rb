require "test_helper"

# D60 slice 2 on screen: brief step 5 "Technical test". Roles, the upload and approval round trip,
# the download headers (plan §d), the stepper, and the house form rules on the rendered HTML.
class TestCaseScreensTest < ActionDispatch::IntegrationTest
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
  end

  def form_params(params) = { test_case: params }

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    doc.css("form").each { |form| assert_empty form.css("form") }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
    refute_match(/fa-eye\b/, response.body)
    refute_match(/Terapkan|unggah|berkas|Tautan/i, doc.at("body").text, "wording standard")
  end

  test "the consultant uploads, HR PIC approves, then the brief completes" do
    sign_in_as staff_user("consultant")
    get staff_job_test_case_step_path(@job)
    assert_response :success
    assert_select "input[type=file][name='test_case[case_file]']"
    assert_select "select[name='test_case[criteria][0][activity_id]'] option", @job.activities.size + 1
    assert_house_rules
    post staff_job_test_cases_path(@job), params: form_params(case_version_params(@job))
    assert_redirected_to staff_job_test_case_step_path(@job)
    follow_redirect!
    assert_includes response.body, "Not scanned by antivirus"
    assert_select "form[action$='/approve']", 0, "a consultant has no approve action"

    sign_in_as staff_user("hr_pic")
    get staff_job_test_case_step_path(@job)
    assert_select "input[type=file]", 0, "HR does not edit the case"
    assert_select "form[action$='/approve'] button[name=commit]", 1
    assert_house_rules
    digest = css_select("form.test-case-approve input[name=content_digest]").first["value"]
    post staff_job_test_case_approve_path(@job, TechnicalTestCase.latest_for(@job)), params: { content_digest: digest }
    assert_redirected_to staff_job_test_case_step_path(@job)
    assert TechnicalTestCase.latest_for(@job).approved?
    assert Briefs::Complete.call(job: @job.reload, actor: staff_user("hr_pic")).ok?
  end

  test "F-02: HR approves only the content HR saw; a change after HR opened the page is refused" do
    TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params: case_version_params(@job).merge(instructions: "Dibaca HR"))
    sign_in_as staff_user("hr_pic")
    get staff_job_test_case_step_path(@job)
    form = css_select("form.test-case-approve").first
    digest = form.at_css("input[name=content_digest]")["value"]
    TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params: case_version_params(@job).merge(instructions: "Diganti"))
    post form["action"], params: { content_digest: digest }
    assert_response :unprocessable_content
    assert_includes response.body, "This version has changed since you opened it. Please read it again."
    refute TechnicalTestCase.latest_for(@job).approved?
    post form["action"], params: {}
    refute TechnicalTestCase.latest_for(@job).approved?, "an approval without the fingerprint is refused"
    get staff_job_test_case_step_path(@job)
    fresh = css_select("form.test-case-approve input[name=content_digest]").first["value"]
    post form["action"], params: { content_digest: fresh }
    assert TechnicalTestCase.latest_for(@job).approved?, "control: approving what is on screen works"
  end

  test "a refused save keeps what was typed and says what to fix" do
    sign_in_as staff_user("consultant")
    params = case_version_params(@job).merge(time_limit_minutes: "90", instructions: "Teks yang diketik")
    post staff_job_test_cases_path(@job), params: form_params(params)
    assert_response :unprocessable_content
    assert_includes response.body, "Time limit 90 minutes is out of range"
    assert_select "textarea[name='test_case[instructions]']", text: "Teks yang diketik"
    assert_select "input[name='test_case[time_limit_minutes]'][value='90']"
  end

  test "owner, reviewer and admin read only; HR PIC cannot save; a consultant cannot approve" do
    tc = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params: case_version_params(@job)).test_case
    %w[owner reviewer admin].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_case_step_path(@job)
      assert_response :success
      assert_select "section.content form", 0, "#{role} sees a form"
    end
    sign_in_as staff_user("hr_pic")
    post staff_job_test_cases_path(@job), params: form_params(case_version_params(@job).merge(instructions: "HR mengubah"))
    assert_redirected_to staff_jobs_path
    refute_equal "HR mengubah", tc.reload.instructions
    sign_in_as staff_user("consultant")
    post staff_job_test_case_approve_path(@job, tc)
    assert_redirected_to staff_jobs_path
    refute tc.reload.approved?
  end

  test "the case file downloads as an attachment with nosniff, never inline" do
    tc = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params: case_version_params(@job)).test_case
    sign_in_as staff_user("reviewer")
    get staff_job_test_case_file_path(@job, tc)
    assert_response :success
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert response.body.b.start_with?("PK\x03\x04".b)
  end

  test "the stepper shows step 5 for a package that runs S2, with its open problem; package 2 has no step 5" do
    sign_in_as staff_user("consultant")
    get staff_job_brief_step_path(@job, 4)
    assert_select ".job-brief-stepper__item", 5
    assert_select ".job-brief-stepper a[href='#{staff_job_test_case_step_path(@job)}']"
    get staff_job_brief_path(@job)
    assert_includes response.body, "Step 5: Technical test"
    assert_includes response.body, "The technical test has not been created"
    plain = briefed_job(golongan: 2, package: 2, complete: false, test_case: false)
    get staff_job_brief_step_path(plain, 4)
    assert_select ".job-brief-stepper__item", 4
    get staff_job_test_case_step_path(plain)
    assert_response :not_found
  end

  test "after approval the editor offers version 2 and asks for the reason" do
    tc = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params: case_version_params(@job)).test_case
    TestCases::Approve.call(test_case: tc, actor: staff_user("hr_pic"))
    sign_in_as staff_user("consultant")
    get staff_job_test_case_step_path(@job)
    assert_includes response.body, "Saving will create version 2"
    assert_select "textarea[name='test_case[new_version_reason]']"
    assert_house_rules
  end
end
