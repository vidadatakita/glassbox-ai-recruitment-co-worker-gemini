require "test_helper"

# Competency test bank, slice A (FLOW §7, 17 Oct 2026): the HR Admin builds the bank, submits it,
# and the HR Manager approves or returns it. Guards are proven at the service AND the database.
class TestCases::QuestionBankTest < ActiveSupport::TestCase
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
    @activity = @job.activities.first
    @competency = @job.competencies.first
  end

  def save(action, params = {}, actor: @admin, **kw) = TestCases::SaveBank.call(job: @job, actor:, action:, params:, **kw)

  def choice_params(section: "technical", prompt: "Which total is right?")
    link = section == "technical" ? "a:#{@activity.id}" : "c:#{@competency.id}"
    { section:, kind: "multiple_choice", link_id: link, prompt:, options: { "0" => "Rp1.000", "1" => "", "2" => "Rp2.000" }, correct: "2" }
  end

  def written_params(section: "role")
    { section:, kind: "written", link_id: section == "technical" ? "a:#{@activity.id}" : "c:#{@competency.id}",
      prompt: "A customer is angry about a late order. What do you do?", anchor_1: "blames others", anchor_3: "apologises and checks",
      anchor_5: "apologises, checks, offers a dated fix" }
  end

  # A bank at exactly the minimum: 10 technical, 6 role (defaults 5 and 3 drawn).
  def full_bank!
    10.times { |i| assert save("add", choice_params(prompt: "Technical question #{i}")).ok? }
    5.times { |i| assert save("add", choice_params(section: "role", prompt: "Role question #{i}")).ok? }
    assert save("add", written_params).ok?
    QuestionBank.latest_for(@job)
  end

  def decide(bank, action, actor:, **kw) = TestCases::BankDecision.call(bank:, actor:, action:, **kw)

  test "the first question creates version 1 as a draft, under the HR Admin, with an audit row" do
    assert_difference -> { JobBriefChange.where(job: @job, step: "5").count }, 1 do
      assert save("add", choice_params).ok?
    end
    bank = QuestionBank.latest_for(@job)
    assert_equal [1, @admin.id, "draft"], [bank.version, bank.created_by_id, bank.state]
    q = bank.questions.first
    assert_equal ["Rp1.000", "Rp2.000"], q.options
    assert_equal 1, q.correct_index, "the blank middle slot must not shift the correct answer"
    assert_equal @activity.description, q.activity_text
  end

  test "a role question refuses an activity link and a technical one refuses a competency link" do
    result = save("add", choice_params.merge(link_id: "c:#{@competency.id}"))
    refute result.ok?
    assert_match(/technical question tests an activity/, result.errors.join)
    refute save("add", choice_params(section: "role").merge(link_id: "a:#{@activity.id}")).ok?
    assert_nil QuestionBank.latest_for(@job), "a refused first save leaves no bank behind"
  end

  test "multiple choice needs 2 to 6 distinct options and a marked answer" do
    assert_match(/2 to 6 answer options/, save("add", choice_params.merge(options: { "0" => "only one" })).errors.join)
    assert_match(/mark the correct answer/, save("add", choice_params.merge(correct: "1")).errors.join, "the correct slot is blank")
    assert_match(/two answer options are the same/, save("add", choice_params.merge(options: { "0" => "A", "1" => "a" }, correct: "0")).errors.join)
  end

  test "an HR Manager cannot build the bank" do
    result = save("add", choice_params, actor: @manager)
    refute result.ok?
    assert_nil QuestionBank.latest_for(@job)
  end

  test "submit is refused until both sections reach twice their draw, then locks the questions" do
    save("add", choice_params)
    bank = QuestionBank.latest_for(@job)
    result = decide(bank, "submit", actor: @admin)
    refute result.ok?
    assert_match(/Technical competency: 1 of at least 10/, result.errors.join(" "))
    assert_match(/Role competency: 0 of at least 6/, result.errors.join(" "))

    bank = full_bank!
    assert decide(bank, "submit", actor: @admin).ok?
    assert bank.reload.submitted?
    assert_match(/submitted for the HR Manager's approval/, save("add", choice_params).errors.join)
    refused_by_database { bank.questions.first.update_column(:prompt, "changed behind the app") }
  end

  test "a written question without its three anchors blocks the submission" do
    bank = full_bank!
    written = bank.questions.find(&:written?)
    assert save("update", written_params.merge(anchor_5: ""), question_id: written.id).ok?
    result = decide(bank.reload, "submit", actor: @admin)
    refute result.ok?
    assert_match(/without all three scoring anchors/, result.errors.join)
  end

  test "the HR Manager approves a submitted bank; an HR Manager who submitted it cannot; the superadmin may approve its own" do
    bank = full_bank!
    refute decide(bank, "approve", actor: @manager).ok?, "a draft that was never submitted is not approved"
    assert decide(bank, "submit", actor: @admin).ok?
    refute decide(bank.reload, "approve", actor: @admin).ok?, "an HR Admin does not approve"
    assert decide(bank.reload, "approve", actor: @manager).ok?
    assert_equal [@manager.id, "approved"], [bank.reload.approved_by_id, bank.state]

    # Vida 10:43: the superadmin may create, submit and approve the same version.
    super_job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    boss = staff_user("admin")
    own = TestCases::SaveBank.call(job: super_job, actor: boss, action: "settings", params: { technical_draw: "1", role_draw: "1" }).bank
    activity, competency = super_job.activities.first, super_job.competencies.first
    2.times { |i| assert TestCases::SaveBank.call(job: super_job, actor: boss, action: "add", params: choice_params(prompt: "T#{i}").merge(link_id: "a:#{activity.id}")).ok? }
    2.times { |i| assert TestCases::SaveBank.call(job: super_job, actor: boss, action: "add", params: choice_params(section: "role", prompt: "R#{i}").merge(link_id: "c:#{competency.id}")).ok? }
    assert decide(own.reload, "submit", actor: boss).ok?
    assert decide(own.reload, "approve", actor: boss).ok?, "the superadmin approves its own version"

    # Control: an HR Manager who submitted a version (as a superadmin could not be refused) is refused.
    refute TestCases::Authority.may_review_bank?(@manager, QuestionBank.new(created_by_id: @admin.id, submitted_by_id: @manager.id))
  end

  test "the database refuses an approval by the creator or by an HR Admin, and one without a submission" do
    bank = full_bank!
    refused_by_database { bank.update_columns(approved_at: Time.current, approved_by_id: @manager.id) }
    assert decide(bank, "submit", actor: @admin).ok?
    other_admin = staff_user("consultant")
    refused_by_database { bank.reload.update_columns(approved_at: Time.current, approved_by_id: other_admin.id) }
    refused_by_database { bank.reload.update_columns(approved_at: Time.current, approved_by_id: @admin.id) }
    bank.reload.update_columns(approved_at: Time.current, approved_by_id: @manager.id) # control: the right person passes
    assert bank.reload.approved?
  end

  test "approve refuses a bank that changed since the HR Manager's screen was opened" do
    bank = full_bank!
    seen = bank.content_digest
    assert decide(bank, "submit", actor: @admin).ok?
    assert decide(bank.reload, "withdraw", actor: @admin).ok?
    assert save("update", choice_params(prompt: "Edited after the HR Manager looked"), question_id: bank.questions.first.id).ok?
    assert decide(bank.reload, "submit", actor: @admin).ok?
    result = decide(bank.reload, "approve", actor: @manager, seen_digest: seen)
    refute result.ok?
    assert_equal [TestCases::BankDecision::STALE], result.errors
    assert decide(bank.reload, "approve", actor: @manager, seen_digest: bank.content_digest).ok?
  end

  test "return needs a reason and puts the bank back to draft; the reason is in the history" do
    bank = full_bank!
    assert decide(bank, "submit", actor: @admin).ok?
    assert_match(/Write the reason/, decide(bank.reload, "return", actor: @manager, reason: "   ").errors.join)
    assert decide(bank.reload, "return", actor: @manager, reason: "Question 3 has two right answers.").ok?
    assert bank.reload.draft?
    last = JobBriefChange.where(job: @job, step: "5").order(:id).last
    assert_equal ["return", "Question 3 has two right answers.", @manager.id], [last.changes_made.dig("decision", 1), last.changes_made.dig("reason", 1), last.actor_id]
  end

  test "a change to an approved bank is version 2 with a reason, copying every question" do
    bank = full_bank!
    decide(bank, "submit", actor: @admin)
    decide(bank.reload, "approve", actor: @manager)
    assert_match(/reason for the new version is required/, save("settings", { technical_draw: "5" }).errors.join)
    assert save("settings", { technical_draw: "6", new_version_reason: "One more technical question per applicant" }).ok?
    v2 = QuestionBank.latest_for(@job)
    assert_equal [2, 16, 6], [v2.version, v2.questions.count, v2.technical_draw]
    assert_equal bank.id, QuestionBank.current_for(@job).id, "version 1 stays in force until version 2 is approved"
    refused_by_database { bank.questions.first.destroy }
  end

  test "accepting an AI proposal adds only the ticked rows, marked as AI drafts" do
    payload = { "bank" => { "questions" => [
      { "section" => "technical", "kind" => "multiple_choice", "link_id" => @activity.id.to_s, "prompt" => "AI one",
        "options" => { "0" => "x", "1" => "y" }, "correct" => "1" },
      { "section" => "role", "kind" => "written", "link_id" => @competency.id.to_s, "prompt" => "AI two",
        "anchor_1" => "a", "anchor_3" => "b", "anchor_5" => "c" }
    ] } }
    suggestion = BriefSuggestion.create!(job: @job, actor: @admin, model_id: "m", prompt_version: "p", payload:, created_at: Time.current)
    assert_match(/Tick at least one/, save("accept_ai", { picks: [] }, suggestion:).errors.join)
    assert save("accept_ai", { picks: ["1"] }, suggestion:).ok?
    questions = QuestionBank.latest_for(@job).questions
    assert_equal [["AI two", "ai", @competency.id]], questions.map { |q| [q.prompt, q.source, q.competency_id] }
  end

  test "ready_for_open?: an approved bank is a test in force on its own (slice B); a draft is not; package 2 is always ready" do
    refute TestCases::Readiness.ready_for_open?(@job)
    bank = full_bank!
    refute TestCases::Readiness.ready_for_open?(@job), "a draft bank does not open the portal"
    decide(bank, "submit", actor: @admin)
    refute TestCases::Readiness.ready_for_open?(@job), "a submitted bank does not either"
    decide(bank.reload, "approve", actor: @manager)
    assert TestCases::Readiness.ready_for_open?(@job)
    assert_nil TestCases::Readiness.refusal(@job)
    assert_empty TestCases::Requirement.problems(@job.reload), "the brief accepts the approved bank"
    assert TestCases::Readiness.ready_for_open?(briefed_job(golongan: 2, package: 2, complete: false, test_case: false))
  end
end
