require "test_helper"

class StageTest < ActiveSupport::TestCase
  test "weight and threshold can change while the stage is a draft" do
    stage = create_stage
    assert stage.update(threshold: 70, weight: 25)
  end

  test "weight and threshold are locked once the stage has opened (rule 3)" do
    stage = create_stage
    stage.update!(status: "open", opened_at: Time.current)
    refute stage.update(threshold: 60)
    assert_includes stage.errors[:threshold], "is locked since the stage opened"
    refute stage.update(weight: 30)
  end

  test "unlock_for_change is the only way to change a locked threshold" do
    stage = create_stage
    stage.update!(status: "open", opened_at: Time.current)
    Stages::ChangeThreshold.call(stage:, new_threshold: 60, reason: "uji", actor_id: ScoringFactory::ACTOR_ID)
    assert_equal BigDecimal("60.0"), stage.reload.threshold
    refute stage.update(threshold: 55), "the unlock must not outlive the block"
  end

  # Since 2026-10-10 (test-engine F-04) the database also refuses a locked threshold edit that
  # no StageChange in the same transaction names, so the model unlock alone is not enough.
  test "the database refuses a locked threshold edit without a StageChange, even through the unlock" do
    stage = create_stage
    stage.update!(status: "open", opened_at: Time.current)
    error = assert_raises(ActiveRecord::StatementInvalid) { stage.unlock_for_change { stage.update!(threshold: 60) } }
    assert_match(/StageChange named in the same transaction/, error.message)
  end
end
