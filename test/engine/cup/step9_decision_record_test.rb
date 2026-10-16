require "test_helper"

# Step 9 (FLOW §1, §5.1 Q1): the human decision record. Risk hunted: a reject that follows the AI
# advice WITHOUT a written reason, which would make the decision "solely automated" under UU 27/2022
# Pasal 10; and the second guard (the database) being the only one, so the screen would show a
# 500 instead of the note box. Each rule has its refusal at the service AND at the database.
class CupStep9DecisionRecordTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @hr = staff_user("hr_pic")
    @participation = apply_with_cv!(@job)
    Stages::Open.call(stage: s1(@job))
  end

  def advice!(advice, score)
    StageRecommendation.create!(participation: @participation, requested_by: @hr, status: "ready", advice:, ai_score: score,
                                model_id: "demo-no-ai (sample data)", prompt_version: Progression::Recommend::PROMPT_VERSION,
                                summary: "sample", created_at: Time.current)
  end

  def choose(choice, note: nil, seen: StageRecommendation.latest_for(@participation)&.id, actor: @hr)
    Progression::Choose.call(participation: @participation, actor:, choice:, note:, seen_recommendation_id: seen)
  end

  test "following the AI advice on a reject needs a written reason: refused at the service with the note field named" do
    advice!("tidak_lanjut", 40)
    error = assert_raises(Progression::Choose::Refused) { choose("ikut_ai") }
    assert_equal :note, error.field
    assert_match(/reason is required for every Do not continue/i, error.message)
    assert_nil @participation.reload.progression_choice, "nothing recorded on a refusal"

    # Control: with a reason the record carries who, when, the advice followed, the direction and the note.
    choice = choose("ikut_ai", note: "Tax filing only; no journal preparation, which the role needs from day one.")
    assert_equal %w[ikut_ai tidak_lanjut], [choice.choice, choice.direction]
    assert_equal @hr.id, choice.actor_id
    assert_equal StageRecommendation.latest_for(@participation).id, choice.stage_recommendation_id
    decision = @participation.reload.current_decision
    assert_equal %w[eliminate manual progression_choice], [decision.outcome, decision.basis, decision.reason_code]
    assert_equal @hr.id, decision.decided_by_id
    assert_equal choice.note, decision.note
  end

  test "following the AI advice to continue needs no reason, and the candidate enters the next stage" do
    advice!("lanjut", 80)
    choice = choose("ikut_ai")
    assert_equal %w[ikut_ai lanjut], [choice.choice, choice.direction]
    assert_nil choice.note
    assert @participation.job_application.participations.joins(:stage).where.not(stages: { code: "S1" }).exists?, "Continue adds the next stage"
  end

  test "departing from the advice needs a reason in both directions" do
    advice!("lanjut", 80)
    error = assert_raises(Progression::Choose::Refused) { choose("tidak_lanjut") }
    assert_equal :note, error.field

    @participation = apply_with_cv!(@job, name: "Second Applicant")
    advice!("tidak_lanjut", 40)
    error = assert_raises(Progression::Choose::Refused) { choose("lanjut") }
    assert_equal :note, error.field
    assert_match(/departs from the AI advice/i, error.message)
  end

  test "the database refuses a Do-not-continue record without a note even when the service is bypassed" do
    advice!("tidak_lanjut", 40)
    error = refused_by_database do
      ProgressionChoice.create!(participation: @participation, stage_recommendation: StageRecommendation.latest_for(@participation),
                                choice: "ikut_ai", direction: "tidak_lanjut", note: "   ", actor: @hr, created_at: Time.current)
    end
    assert_match(/progression_choices_tidak_lanjut_has_note/, error.message)
  end

  test "a stale advice (refreshed after the screen was read) is refused, so the record never names advice the person did not see" do
    old = advice!("lanjut", 80)
    advice!("tidak_lanjut", 40)
    error = assert_raises(Progression::Choose::Refused) { choose("ikut_ai", note: "x", seen: old.id) }
    assert_match(/refreshed/i, error.message)
  end
end
