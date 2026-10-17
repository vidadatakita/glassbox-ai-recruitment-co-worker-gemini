require "test_helper"
require_relative "bank_engine_helpers"

# Independent test pass, competency bank slice A, through HTTP: ids of another vacancy or company in the URL,
# the stale-screen approval, and the house form rules on the step page for every role and state.
class BankScreensEngineTest < ActionDispatch::IntegrationTest
  include BankEngineHelpers

  setup { bank_setup! }

  def step_path(job = @job) = staff_job_test_case_step_path(job)

  def assert_house_rules(label)
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "#{label}: a form inside a form"
    assert_empty doc.css("form form"), "#{label}: nested form"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "#{label}: disabled submit"
    doc.css("button[name], input[type=submit][name]").each { |b| assert b["value"].present?, "#{label}: named submit without a value" }
    doc.css("form.question-bank-item__remove").each do |f|
      assert_empty f.ancestors("form"), "#{label}: remove button inside another form"
      assert_equal "delete", f.at("input[name=_method]")&.[]("value"), "#{label}: remove form is not a DELETE"
    end
    refute_match(/Terapkan/i, doc.at("body").text)
  end

  # Cross-company access is not testable here: the database allows one client company
  # (enforce_single_tenant, TENANCY=single), so a second company cannot be created. Stated as a gap.

  test "a bank, question or AI proposal of another vacancy cannot be reached through this vacancy's URL" do
    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    other_bank = full_bank!(job: other)
    assert decide_bank(other_bank, "submit", actor: @admin).ok?
    assert save_bank("add", mc_params).ok?
    foreign_q = other_bank.questions.first
    suggestion = BriefSuggestion.create!(job: other, actor: @admin, model_id: "m", prompt_version: "p", created_at: Time.current,
                                         payload: { "bank" => { "questions" => [] } })

    sign_in_as @manager
    post staff_job_question_bank_decision_path(@job, other_bank), params: { decision: "approve", content_digest: other_bank.content_digest }
    assert_response :not_found
    refute other_bank.reload.approved?

    sign_in_as @admin
    patch staff_job_question_bank_question_path(@job, foreign_q.id), params: { bank: mc_params(prompt: "Hijacked") }
    assert_response :unprocessable_content
    delete staff_job_question_bank_question_path(@job, foreign_q.id)
    assert_response :unprocessable_content
    assert_equal "Technical 0", foreign_q.reload.prompt
    post staff_job_question_bank_accept_ai_path(@job, suggestion), params: { bank: { picks: ["0"] } }
    assert_response :not_found
  end

  test "the HR Manager's screen digest is refused after a withdraw-edit-resubmit; a missing digest too" do
    bank = submitted_bank!
    sign_in_as @manager
    get step_path
    seen = Nokogiri::HTML(response.body).at("input[name=content_digest]")["value"]
    assert_equal bank.content_digest, seen

    assert decide_bank(bank, "withdraw", actor: @admin).ok?
    assert save_bank("update", mc_params(prompt: "Quietly changed answer key").merge(correct: "0"), question_id: bank.questions.first.id).ok?
    assert decide_bank(bank, "submit", actor: @admin).ok?

    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "approve", content_digest: seen }
    assert_response :unprocessable_content
    assert_includes response.body, "has changed since you opened it"
    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "approve" }
    assert_response :unprocessable_content
    refute bank.reload.approved?
    post staff_job_question_bank_decision_path(@job, bank), params: { decision: "approve", content_digest: bank.content_digest }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert bank.reload.approved?
  end

  test "house rules hold on the step page for every role in draft, submitted and approved" do
    bank = full_bank!
    assert save_bank("add", written_params).ok?
    sign_in_as @admin
    get step_path
    assert_response :success
    assert_select "form.question-bank-item__remove", 17
    assert_select "input[name=decision][value=submit]", 1
    assert_house_rules("HR Admin, draft")

    assert decide_bank(bank, "submit", actor: @admin).ok?
    get step_path
    assert_select "form.question-bank-item__remove", 0
    assert_select "input[name=decision][value=withdraw]", 1
    assert_house_rules("HR Admin, submitted")
    sign_in_as @manager
    get step_path
    assert_select "input[name=decision][value=approve]", 1
    assert_house_rules("HR Manager, submitted")

    assert decide_bank(bank, "approve", actor: @manager, seen_digest: bank.reload.content_digest).ok?
    [@admin, @manager, staff_user("admin")].each do |user|
      sign_in_as user
      get step_path
      assert_response :success
      assert_select "input[name=decision]", 0
      assert_select "form.question-bank-item__remove", 0
      assert_house_rules("#{user.role}, approved")
    end
  end

  test "a refused settings save renders 422 with the reason; a success redirects" do
    assert save_bank("add", mc_params).ok?
    sign_in_as @admin
    post staff_job_question_bank_settings_path(@job), params: { bank: { technical_draw: "abc" } }
    assert_response :unprocessable_content
    assert_includes response.body, "must be a whole number"
    post staff_job_question_bank_settings_path(@job), params: { bank: { technical_draw: "21" } }
    assert_response :unprocessable_content
    assert_includes response.body, "out of range"
    post staff_job_question_bank_settings_path(@job), params: { bank: { technical_draw: "4" } }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal 4, QuestionBank.latest_for(@job).technical_draw
  end

  test "a package without S2 has no bank address for settings, decisions, AI draft or the step page" do
    job = briefed_job(golongan: 2, package: 2, complete: false, test_case: false)
    sign_in_as @admin
    post staff_job_question_bank_settings_path(job), params: { bank: { technical_draw: "4" } }
    assert_response :not_found
    post staff_job_question_bank_ai_draft_path(job)
    assert_response :not_found
    post staff_job_question_bank_decision_path(job, 1), params: { decision: "submit" }
    assert_response :not_found
    assert_nil QuestionBank.latest_for(job)
  end
end
