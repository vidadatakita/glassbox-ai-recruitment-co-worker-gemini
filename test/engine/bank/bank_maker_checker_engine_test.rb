require "test_helper"
require_relative "bank_engine_helpers"

# Independent test pass, competency bank slice A: maker is not the checker, and a submitted or approved bank
# cannot be changed, proven at the service and again at the database (the trigger must hold when the
# application has a bug). Every refusal has a control beside it showing the right person passes.
class BankMakerCheckerEngineTest < ActiveSupport::TestCase
  include BankEngineHelpers

  setup { bank_setup! }

  test "control: a second HR Manager approves, and the approver is recorded" do
    bank = submitted_bank!
    other_manager = staff_user("owner")
    assert decide_bank(bank, "approve", actor: other_manager, seen_digest: bank.content_digest).ok?
    assert_equal other_manager.id, bank.reload.approved_by_id
  end

  test "each step refuses the wrong role, and an approved bank is never approved twice" do
    bank = full_bank!
    refute decide_bank(bank, "submit", actor: @manager).ok?, "an HR Manager does not submit"
    assert_match(/not submitted this question bank/, decide_bank(bank, "approve", actor: @manager, seen_digest: bank.content_digest).errors.join)
    refute decide_bank(bank, "frobnicate", actor: @admin).ok?
    assert decide_bank(bank, "submit", actor: @admin).ok?
    refute decide_bank(bank, "withdraw", actor: @manager).ok?, "an HR Manager does not withdraw; they return with a reason"
    refute decide_bank(bank, "return", actor: @admin, reason: "I changed my mind").ok?, "an HR Admin does not return"
    assert bank.reload.submitted?
    assert decide_bank(bank, "approve", actor: @manager, seen_digest: bank.content_digest).ok?
    assert_match(/already approved/, decide_bank(bank, "approve", actor: staff_user("owner")).errors.join)
    refute decide_bank(bank, "withdraw", actor: @admin).ok?, "an approved bank is never taken back to draft"
    assert bank.reload.approved?
  end

  # The creator clause alone refuses the creator; this pins the ROLE clause with an HR Admin who did
  # not create the bank (return has no database backstop: it never touches approved_at).
  test "an HR Admin who did not create the bank can neither return nor approve it" do
    bank = submitted_bank!
    other_admin = staff_user("consultant")
    returned = decide_bank(bank, "return", actor: other_admin, reason: "Looks wrong to me")
    assert_equal ["The question bank is approved by the HR Manager."], returned.errors
    approved = decide_bank(bank, "approve", actor: other_admin, seen_digest: bank.content_digest)
    assert_equal ["The question bank is approved by the HR Manager."], approved.errors
    assert bank.reload.submitted?
  end

  # Vida 17 Oct 2026, 10:43: the superadmin may create, submit and approve the same version (the
  # person rule does not apply to the superadmin; the role rule still does).
  test "the superadmin may create, submit and approve the same version, in the service and the database" do
    boss = staff_user("admin")
    bank = full_bank!(actor: boss)
    assert decide_bank(bank, "submit", actor: boss).ok?
    assert_equal [boss.id, boss.id], [bank.reload.created_by_id, bank.submitted_by_id]
    assert decide_bank(bank, "approve", actor: boss, seen_digest: bank.content_digest).ok?
    assert_equal boss.id, bank.reload.approved_by_id

    job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    raw = full_bank!(actor: boss, job:)
    raw.update_columns(submitted_at: Time.current, submitted_by_id: boss.id)
    raw.update_columns(approved_at: Time.current, approved_by_id: boss.id) # the trigger lets the superadmin through
    assert raw.reload.approved?
  end

  # Maker is not the checker for the HR Manager: neither the creator nor the submitter approves. The
  # screen never lets an HR Manager submit, so the submitter is set directly, as a bug or a script would.
  test "an HR Manager who submitted a version cannot approve it; another HR Manager can" do
    bank = full_bank!
    bank.update_columns(submitted_at: Time.current, submitted_by_id: @manager.id)
    result = decide_bank(bank, "approve", actor: @manager, seen_digest: bank.content_digest)
    assert_equal ["The person who submitted this question bank cannot approve it; another HR Manager approves it."], result.errors
    error = refused_by_database { bank.update_columns(approved_at: Time.current, approved_by_id: @manager.id) }
    assert_match(/created or submitted the bank cannot approve it/, error.message)
    refute bank.reload.approved?

    other_manager = staff_user("owner")
    assert decide_bank(bank, "approve", actor: other_manager, seen_digest: bank.content_digest).ok?, "control: another HR Manager approves"
    assert_equal other_manager.id, bank.reload.approved_by_id
  end

  test "the database refuses an HR Manager approving a version they created" do
    row = { job_id: @job.id, version: 1, created_by_id: @manager.id, created_at: Time.current, updated_at: Time.current }
    QuestionBank.insert!(row)
    bank = QuestionBank.find_by(job_id: @job.id, version: 1)
    16.times do |i|
      BankQuestion.insert!({ question_bank_id: bank.id, section: i < 10 ? "technical" : "role", kind: "multiple_choice", position: i + 1,
                             activity_id: (@activity.id if i < 10), competency_id: (@competency.id if i >= 10), prompt: "Q#{i}",
                             options: %w[a b], correct_index: 0, source: "manual", created_at: Time.current, updated_at: Time.current })
    end
    bank.update_columns(submitted_at: Time.current, submitted_by_id: @admin.id)
    error = refused_by_database { bank.update_columns(approved_at: Time.current, approved_by_id: @manager.id) }
    assert_match(/created or submitted the bank cannot approve it/, error.message)
    bank.update_columns(approved_at: Time.current, approved_by_id: staff_user("owner").id) # control: another HR Manager passes
    assert bank.reload.approved?
  end

  test "submission needs exactly twice the draw per section: one short is refused, the minimum passes" do
    9.times { |i| assert save_bank("add", mc_params(prompt: "Technical #{i}")).ok? }
    6.times { |i| assert save_bank("add", mc_params(section: "role", prompt: "Role #{i}")).ok? }
    bank = QuestionBank.latest_for(@job)
    assert_match(/Technical competency: 9 of at least 10/, decide_bank(bank, "submit", actor: @admin).errors.join)
    assert save_bank("add", mc_params(prompt: "Technical 9")).ok?
    assert save_bank("settings", { role_draw: "4" }).ok?
    assert_match(/Role competency: 6 of at least 8/, decide_bank(bank, "submit", actor: @admin).errors.join)
    assert save_bank("settings", { role_draw: "3" }).ok?
    assert decide_bank(bank, "submit", actor: @admin).ok?
  end

  test "the service refuses every change to a submitted bank with the reason, before the database has to" do
    bank = submitted_bank!
    message = /submitted for the HR Manager's approval/
    assert_match message, save_bank("add", mc_params).errors.join
    assert_match message, save_bank("update", mc_params(prompt: "x"), question_id: bank.questions.first.id).errors.join
    assert_match message, save_bank("remove", {}, question_id: bank.questions.first.id).errors.join
    assert_match message, save_bank("settings", { technical_draw: "6" }).errors.join
    assert_equal [16, 5], [bank.questions.count, bank.reload.technical_draw]
  end

  test "a return without a written reason is refused and the bank stays submitted" do
    bank = submitted_bank!
    [nil, "", "   \n "].each do |reason|
      assert_match(/Write the reason/, decide_bank(bank, "return", actor: @manager, reason:).errors.join)
    end
    assert bank.reload.submitted?
  end

  test "approve refuses an empty digest (what the screen sends when the field is missing)" do
    bank = submitted_bank!
    result = decide_bank(bank, "approve", actor: @manager, seen_digest: "")
    assert_equal [TestCases::BankDecision::STALE], result.errors
    refute bank.reload.approved?
  end

  test "the database refuses settings, question inserts, edits and deletes on a submitted bank" do
    bank = submitted_bank!
    q = bank.questions.first
    refused_by_database { bank.update_columns(technical_draw: 1) }
    refused_by_database { bank.update_columns(time_limit_minutes: 45) }
    refused_by_database { q.update_columns(prompt: "Edited while submitted") }
    refused_by_database { q.update_columns(correct_index: 0) }
    refused_by_database { BankQuestion.where(id: q.id).delete_all }
    error = refused_by_database do
      BankQuestion.insert!({ question_bank_id: bank.id, section: "technical", kind: "written", position: 99, prompt: "Smuggled in",
                             options: [], source: "manual", created_at: Time.current, updated_at: Time.current })
    end
    assert_match(/submitted for approval/, error.message, "the lock trigger, not a shape constraint, refused it")
    # Control: back to draft, the same edit passes.
    assert decide_bank(bank, "withdraw", actor: @admin).ok?
    q.reload.update_columns(prompt: "Edited in draft")
    assert_equal "Edited in draft", q.reload.prompt
  end

  test "the database refuses moving a question to another bank and deleting any bank version" do
    bank = full_bank!
    other_job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    assert save_bank("add", mc_params(job: other_job), job: other_job).ok?
    other_bank = QuestionBank.latest_for(other_job)
    q = bank.questions.first
    refused_by_database { q.update_columns(question_bank_id: other_bank.id) }
    refused_by_database { QuestionBank.where(id: other_bank.id).delete_all }
    assert_equal bank.id, q.reload.question_bank_id
  end

  test "the database refuses a version inserted already submitted or approved" do
    row = { job_id: @job.id, version: 7, created_by_id: @admin.id, new_version_reason: "Engine probe", created_at: Time.current,
            updated_at: Time.current }
    error = refused_by_database { QuestionBank.insert!(row.merge(submitted_at: Time.current, submitted_by_id: @admin.id)) }
    assert_match(/inserted as a draft/, error.message)
    error = refused_by_database do
      QuestionBank.insert!(row.merge(submitted_at: Time.current, submitted_by_id: @admin.id, approved_at: Time.current,
                                     approved_by_id: @manager.id))
    end
    assert_match(/inserted as a draft/, error.message)
    QuestionBank.insert!(row) # control: a plain draft is accepted
    assert QuestionBank.find_by(job_id: @job.id, version: 7).draft?
  end

  test "the database refuses approving a short or anchorless bank even when the app is bypassed" do
    assert save_bank("add", mc_params).ok?
    short = QuestionBank.latest_for(@job)
    short.update_columns(submitted_at: Time.current, submitted_by_id: @admin.id)
    refused_by_database { short.update_columns(approved_at: Time.current, approved_by_id: @manager.id) }

    job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    bank = full_bank!(job:)
    written = bank.questions.where(section: "role").first
    written.update_columns(kind: "written", options: [], correct_index: nil, anchor_1: "a", anchor_3: "b", anchor_5: " ")
    bank.update_columns(submitted_at: Time.current, submitted_by_id: @admin.id)
    refused_by_database { bank.update_columns(approved_at: Time.current, approved_by_id: @manager.id) }
    # Control: once the anchor is filled (back in draft) the same approval passes.
    bank.update_columns(submitted_at: nil, submitted_by_id: nil)
    written.update_columns(anchor_5: "logs a dated fallback")
    bank.update_columns(submitted_at: Time.current, submitted_by_id: @admin.id)
    bank.update_columns(approved_at: Time.current, approved_by_id: @manager.id)
    assert bank.reload.approved?
  end
end
