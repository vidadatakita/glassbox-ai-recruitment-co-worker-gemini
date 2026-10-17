require "test_helper"

# Competency test bank on screen (brief step 5, 17 Oct 2026): the HR Admin adds questions and
# submits; the HR Manager approves or returns; the house form rules hold on the rendered page.
class QuestionBankScreensTest < ActionDispatch::IntegrationTest
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
    @activity = @job.activities.first
    @competency = @job.competencies.first
  end

  def question(section: "technical", prompt: "Which figure is right?")
    { bank: { section:, kind: "multiple_choice", link_id: section == "technical" ? "a:#{@activity.id}" : "c:#{@competency.id}",
              prompt:, options: { "0" => "Rp1.000", "1" => "Rp2.000" }, correct: "0" } }
  end

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
    doc.css("button[type=submit][name]").each { |b| assert b["value"].present?, "a named submit button without a value" }
    refute_match(/Terapkan/i, doc.at("body").text)
  end

  def fill_bank!
    10.times { |i| post staff_job_question_bank_questions_path(@job), params: question(prompt: "Technical #{i}") }
    6.times { |i| post staff_job_question_bank_questions_path(@job), params: question(section: "role", prompt: "Role #{i}") }
    QuestionBank.latest_for(@job)
  end

  test "the HR Admin builds the bank on the step page, every save redirects, and submits it" do
    sign_in_as @admin
    get staff_job_test_case_step_path(@job)
    assert_response :success
    assert_select "#question-bank h2", /Competency test bank/
    assert_select "form[action$='/technical-test/bank/questions']", 1
    assert_select "form[action$='/technical-test/bank/ai-draft']", 1
    assert_includes response.body, "0 / 10 questions"
    assert_house_rules

    post staff_job_question_bank_questions_path(@job), params: question
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    bank = fill_bank!
    assert_equal 17, bank.questions.count
    get staff_job_test_case_step_path(@job)
    assert_select "form[action$='/#{bank.id}/decision'] input[name=decision][value=submit]", 1
    assert_house_rules

    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "submit" }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert bank.reload.submitted?
  end

  test "a refused question renders the page with the reason, and nothing is saved" do
    sign_in_as @admin
    post staff_job_question_bank_questions_path(@job), params: question.deep_merge(bank: { prompt: "" })
    assert_response :unprocessable_content
    assert_includes response.body, "write the question"
    assert_nil QuestionBank.latest_for(@job)
  end

  test "the HR Manager sees approve and return on a submitted bank, the HR Admin does not; a direct POST is refused" do
    sign_in_as @admin
    bank = fill_bank!
    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "submit" }
    get staff_job_test_case_step_path(@job)
    assert_select "input[name=decision][value=approve]", 0
    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "approve", content_digest: bank.content_digest }
    assert_response :unprocessable_content
    refute bank.reload.approved?

    sign_in_as @manager
    get staff_job_test_case_step_path(@job)
    assert_select "input[name=decision][value=approve]", 1
    assert_select "input[name=decision][value=return]", 1
    assert_select "form[action$='/technical-test/bank/questions']", 0, "the HR Manager does not build the bank"
    assert_house_rules
    post staff_job_question_bank_questions_path(@job), params: question
    assert_response :unprocessable_content
    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "approve", content_digest: bank.content_digest }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal @manager.id, bank.reload.approved_by_id
  end

  test "a package without a technical test has no bank address" do
    job = briefed_job(golongan: 2, package: 2, complete: false, test_case: false)
    sign_in_as @admin
    post staff_job_question_bank_questions_path(job), params: question
    assert_response :not_found
  end
end
