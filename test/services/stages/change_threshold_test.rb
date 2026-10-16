require "test_helper"
require "minitest/mock"

class Stages::ChangeThresholdTest < ActiveSupport::TestCase
  setup do
    @stage = Stages::Open.call(stage: create_stage(threshold: 65))
    @at_62 = create_participation(stage: @stage)
    add_score(@at_62, 62)
    decide!(@at_62, outcome: "eliminate", reason_code: "below_threshold")

    # Score 55 stays BELOW the new threshold (60) on purpose. With a score that passes the
    # new threshold, a broken implementation that re-decides manual decisions would compute
    # "pass" again, change nothing, and the test would stay green (mutation survives).
    @manual = create_participation(stage: @stage)
    add_score(@manual, 55)
    first = decide!(@manual, outcome: "eliminate", reason_code: "below_threshold")
    decide!(@manual, outcome: "pass", basis: "manual", reason_code: "override",
                     note: "Pengalaman cabang relevan", supersedes: first)

    @no_show = create_participation(stage: @stage, attendance: "no_show")
    decide!(@no_show, outcome: "eliminate", basis: "rule", reason_code: "no_show")
  end

  def lower_to_60
    Stages::ChangeThreshold.call(stage: @stage, new_threshold: 60, reason: "Pool kandidat sempit",
                                 actor_id: ScoringFactory::ACTOR_ID)
  end

  test "records the change with old value, new value and reason" do
    lower_to_60
    change = @stage.stage_changes.last
    assert_equal [BigDecimal("65.0"), BigDecimal("60.0"), "Pool kandidat sempit"],
                 [change.old_value, change.new_value, change.reason]
  end

  test "re-decides threshold-based decisions against the new threshold" do
    lower_to_60
    assert_equal "pass", @at_62.reload.current_decision.outcome
  end

  test "keeps manual decisions and rule decisions exactly as they were (rule 3)" do
    manual_before = @manual.current_decision.id
    no_show_before = @no_show.current_decision.id
    lower_to_60
    assert_equal manual_before, @manual.reload.current_decision.id
    assert_equal no_show_before, @no_show.reload.current_decision.id
  end

  test "a change without a reason is refused and changes nothing" do
    assert_raises(ArgumentError) do
      Stages::ChangeThreshold.call(stage: @stage, new_threshold: 60, reason: " ", actor_id: ScoringFactory::ACTOR_ID)
    end
    assert_equal BigDecimal("65.0"), @stage.reload.threshold
    assert_empty @stage.stage_changes
  end

  test "a failure part-way leaves the threshold, the change log and the decisions untouched (§4.3)" do
    Decision.stub(:create!, ->(*) { raise "database went away" }) do
      assert_raises(RuntimeError) { lower_to_60 }
    end
    assert_equal BigDecimal("65.0"), @stage.reload.threshold
    assert_empty @stage.stage_changes
    assert_equal "eliminate", @at_62.reload.current_decision.outcome
  end
end
