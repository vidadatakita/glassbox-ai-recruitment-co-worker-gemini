require "test_helper"
require_relative "bank_engine_helpers"

# Independent test pass, competency bank slice A: what a saved question holds is what the HR Admin meant
# (the right answer, the brief link, the bounds), a new version is a complete copy, the approval
# fingerprint covers what the HR Manager reads. Slice B (Vida, 17 Oct 2026) moved one rule: an
# approved bank is now a test in force on its own (applicants take it in the three-step form), so it
# opens the portal and completes the brief without an uploaded case; a draft bank still decides nothing.
class BankIntegrityEngineTest < ActiveSupport::TestCase
  include BankEngineHelpers

  setup { bank_setup! }

  test "the correct answer follows its slot across leading and middle blank slots" do
    options = { "0" => "", "1" => "Rp100", "2" => "  ", "3" => "Rp200", "4" => "Rp300" }
    assert save_bank("add", mc_params.merge(options:, correct: "3")).ok?
    assert save_bank("add", mc_params.merge(options:, correct: "4", prompt: "Second")).ok?
    first, second = QuestionBank.latest_for(@job).questions.to_a
    assert_equal ["Rp100", "Rp200", "Rp300"], first.options
    assert_equal "Rp200", first.correct_option, "slot 3 was marked; the stored key must name Rp200"
    assert_equal "Rp300", second.correct_option
    assert_match(/mark the correct answer/, save_bank("add", mc_params.merge(options:, correct: "2")).errors.join, "a blank slot is never the answer")
  end

  test "seven options, a whitespace twin and a blank prompt are refused and leave no bank" do
    seven = (0..6).to_h { |i| [i.to_s, "Option #{i}"] }
    assert_match(/2 to 6 answer options/, save_bank("add", mc_params.merge(options: seven, correct: "0")).errors.join)
    assert_match(/two answer options are the same/,
                 save_bank("add", mc_params.merge(options: { "0" => " Rp100 ", "1" => "rp100" }, correct: "0")).errors.join)
    assert_match(/write the question/, save_bank("add", mc_params.merge(prompt: " \n\t ")).errors.join)
    assert_nil QuestionBank.latest_for(@job)
    assert save_bank("add", mc_params.merge(options: seven.first(6).to_h, correct: "5")).ok?, "control: six options pass"
  end

  test "a link must name a row of THIS vacancy's brief, in the section's own table" do
    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    foreign_activity = other.activities.first.id
    foreign_competency = other.competencies.first.id
    assert_match(/not in this vacancy's brief/, save_bank("add", mc_params.merge(link_id: "a:#{foreign_activity}")).errors.join)
    assert_match(/not in this vacancy's brief/, save_bank("add", mc_params.merge(link_id: foreign_activity.to_s)).errors.join)
    assert_match(/not in this vacancy's brief/,
                 save_bank("add", mc_params(section: "role").merge(link_id: "c:#{foreign_competency}")).errors.join)
    assert_match(/choose what the question tests/, save_bank("add", mc_params.merge(link_id: "a:")).errors.join)
    assert_match(/choose what the question tests/, save_bank("add", mc_params.merge(link_id: "x:#{@activity.id}")).errors.join)
    assert_match(/tests an activity/, save_bank("add", mc_params.merge(link_id: "c:#{@competency.id}")).errors.join)
    assert_nil QuestionBank.latest_for(@job)
    assert save_bank("add", mc_params.merge(link_id: @activity.id.to_s)).ok?, "control: a bare id of this brief, in the right section"
    assert_equal @activity.description, QuestionBank.latest_for(@job).questions.first.activity_text
  end

  test "draw and time limit are refused outside 1-20 and 1-60, and for text, signs and huge numbers" do
    assert save_bank("add", mc_params).ok?
    bank = QuestionBank.latest_for(@job)
    { technical_draw: %w[0 21 abc -1 99999999999999999999 2.5], role_draw: %w[0 21],
      time_limit_minutes: %w[0 61 abc] }.each do |field, values|
      values.each do |value|
        result = save_bank("settings", { field => value })
        refute result.ok?, "#{field}=#{value.inspect} was accepted"
      end
    end
    assert_equal [5, 3, 30], bank.reload.slice(:technical_draw, :role_draw, :time_limit_minutes).values
    assert save_bank("settings", { technical_draw: "1", role_draw: "20", time_limit_minutes: "60" }).ok?, "control: the bounds pass"
    assert_equal [1, 20, 60], bank.reload.slice(:technical_draw, :role_draw, :time_limit_minutes).values
    assert save_bank("settings", { technical_draw: "20", time_limit_minutes: "1" }).ok?
    assert_equal [20, 1], bank.reload.slice(:technical_draw, :time_limit_minutes).values
  end

  test "a new version copies every column of every question, the source and the anchors included" do
    full_bank!
    bank = QuestionBank.latest_for(@job)
    assert save_bank("remove", {}, question_id: bank.questions.where(section: "role").first.id).ok?
    assert save_bank("add", written_params).ok?
    suggestion = BriefSuggestion.create!(job: @job, actor: @admin, model_id: "m", prompt_version: "p", created_at: Time.current,
                                         payload: { "bank" => { "questions" => [{ "section" => "technical", "kind" => "multiple_choice",
                                                                                 "link_id" => @activity.id.to_s, "prompt" => "From the AI",
                                                                                 "options" => { "0" => "x", "1" => "y" }, "correct" => "0" }] } })
    assert save_bank("accept_ai", { picks: ["0"] }, suggestion:).ok?
    assert decide_bank(bank, "submit", actor: @admin).ok?
    assert decide_bank(bank, "approve", actor: @manager, seen_digest: bank.reload.content_digest).ok?

    assert save_bank("settings", { time_limit_minutes: "45", new_version_reason: "Longer test" }).ok?
    v2 = QuestionBank.latest_for(@job)
    skip_cols = %w[id question_bank_id created_at updated_at]
    rows = ->(b) { b.questions.reload.map { |q| q.attributes.except(*skip_cols) } }
    assert_equal rows.(bank), rows.(v2)
    assert_includes v2.questions.map(&:source), "ai"
    assert_equal [2, 45, "Longer test", bank.technical_draw, bank.role_draw],
                 [v2.version, v2.time_limit_minutes, v2.new_version_reason, v2.technical_draw, v2.role_draw]
  end

  test "the approval fingerprint changes when any field the HR Manager reads changes" do
    assert save_bank("add", mc_params).ok?
    assert save_bank("add", written_params).ok?
    bank = QuestionBank.latest_for(@job)
    mc, written = bank.questions.to_a
    changes = [
      -> { bank.update_columns(technical_draw: 6) }, -> { bank.update_columns(role_draw: 4) }, -> { bank.update_columns(time_limit_minutes: 31) },
      -> { mc.update_columns(prompt: "Changed") }, -> { mc.update_columns(options: ["Rp1.500", "Rp9.999"]) },
      -> { mc.update_columns(correct_index: 0) }, -> { mc.update_columns(activity_text: "Renamed activity") },
      -> { mc.update_columns(position: 50) }, -> { written.update_columns(anchor_1: "x") }, -> { written.update_columns(anchor_3: "y") },
      -> { written.update_columns(anchor_5: "z") }, -> { written.update_columns(competency_name: "Renamed competency") }
      # source is NOT in the digest. Not a gap: SaveBank never reassigns source and the trigger
      # refuses every bank_questions change while submitted, so it cannot change in the window guarded.
    ]
    changes.each_with_index do |change, i|
      before = bank.reload.content_digest
      change.call
      refute_equal before, bank.reload.content_digest, "change #{i} left the approval fingerprint unchanged"
    end
  end

  test "a question whose brief activity was removed blocks submission and names the question" do
    full_bank!
    bank = QuestionBank.latest_for(@job)
    second = @job.activities.second || flunk("the factory brief needs two activities")
    assert save_bank("update", mc_params.merge(link_id: "a:#{second.id}", prompt: "Tests the second activity"),
                     question_id: bank.questions.first.id).ok?
    problems_before = TestCases::BankReadiness.problems(bank.reload)
    assert_empty problems_before, "control: a full linked bank has no problem"
    second.destroy!
    problems = TestCases::BankReadiness.problems(bank.reload)
    assert_equal 1, problems.size
    assert_match(/Question 1 tests .* no longer in the brief/, problems.first)
    refute decide_bank(bank, "submit", actor: @admin).ok?
  end

  # Rule moved by slice B (17 Oct 2026). Before: an approved bank alone neither opened the portal nor
  # completed the brief (refute ready_for_open?, Complete refused with a "technical test" problem).
  # After: the approved bank is the test in force. The control below keeps the slice-A half that did
  # not move: without any approved test (bank only a draft, no case) the vacancy stays closed.
  test "an approved bank alone opens the portal and completes the brief; a draft bank alone does not" do
    bank = full_bank!
    refute TestCases::Readiness.ready_for_open?(@job), "control: a draft bank and no case is not a test in force"
    refute_nil TestCases::Readiness.refusal(@job)
    refute Briefs::Complete.call(job: @job, actor: @admin).ok?, "control: the brief must not complete with only a draft bank"
    assert decide_bank(bank, "submit", actor: @admin).ok?
    assert decide_bank(bank, "approve", actor: @manager, seen_digest: bank.reload.content_digest).ok?
    assert TestCases::Readiness.ready_for_open?(@job), "slice B: an approved bank is the test in force"
    assert_nil TestCases::Readiness.refusal(@job)
    assert_empty TestCases::Requirement.problems(@job)
    completed = Briefs::Complete.call(job: @job, actor: @admin)
    assert completed.ok?, "the brief must complete with an approved bank: #{completed.problems.map(&:message).inspect}"

    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: true)
    assert save_bank("add", mc_params(job: other), job: other).ok?
    assert QuestionBank.latest_for(other).draft?
    assert TestCases::Readiness.ready_for_open?(other), "a draft bank must not block a vacancy whose case is approved"
    assert Briefs::Complete.call(job: other, actor: @admin).ok?, "a draft bank must not block brief completion"
  end
end
