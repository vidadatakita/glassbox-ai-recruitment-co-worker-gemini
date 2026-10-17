require "test_helper"

# Step 5 next-step guide (17 Oct 2026, Vida: "when it is done, the system must say where to click"):
# one action at the top, following the state of the bank, the case and the brief.
class TechnicalTestGuideTest < ActionDispatch::IntegrationTest
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
  end

  def guide_text = css_select("#next-step").first&.text.to_s.squish

  def full_bank!(job)
    a, c = job.activities.first, job.competencies.first
    10.times { |i| TestCases::SaveBank.call(job:, actor: @admin, action: "add", params: { section: "technical", kind: "multiple_choice", link_id: "a:#{a.id}", prompt: "T#{i}", options: { "0" => "x", "1" => "y" }, correct: "0" }) }
    6.times { |i| TestCases::SaveBank.call(job:, actor: @admin, action: "add", params: { section: "role", kind: "multiple_choice", link_id: "c:#{c.id}", prompt: "R#{i}", options: { "0" => "x", "1" => "y" }, correct: "0" }) }
    QuestionBank.latest_for(job)
  end

  test "walks the user from building the bank to completing the brief to the job ad" do
    sign_in_as @admin
    get staff_job_test_case_step_path(@job)
    assert_match(/Build the technical test/, guide_text)

    bank = full_bank!(@job)
    get staff_job_test_case_step_path(@job)
    assert_match(/question bank is ready/, guide_text)
    assert_select "#next-step a[href$='#question-bank']", text: /Submit for approval/

    TestCases::BankDecision.call(bank:, actor: @admin, action: "submit")
    get staff_job_test_case_step_path(@job)
    assert_match(/Waiting for the HR Manager/, guide_text)

    sign_in_as @manager
    get staff_job_test_case_step_path(@job)
    assert_match(/waits for your approval/, guide_text)
    TestCases::BankDecision.call(bank: bank.reload, actor: @manager, action: "approve")

    sign_in_as @admin
    get staff_job_test_case_step_path(@job)
    assert_match(/The technical test is approved/, guide_text)
    assert_select "#next-step form[action=?] button", staff_job_brief_complete_path(@job), text: /Complete brief/
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"

    post staff_job_brief_complete_path(@job)
    get staff_job_test_case_step_path(@job)
    assert_match(/brief is complete/, guide_text)
    assert_select "#next-step a[href=?]", staff_job_ad_path(@job), text: /Write the job ad/
  end
end
