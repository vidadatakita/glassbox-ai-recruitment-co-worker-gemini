require "test_helper"

class ScoreEntryTest < ActiveSupport::TestCase
  setup { @participation = create_participation(stage: create_stage) }

  test "a correction supersedes the old entry, which drops out of current" do
    first = add_score(@participation, 60)
    second = add_score(@participation, 64, supersedes: first, reason: "typo: 60 entered for 64")
    assert_equal [second.id], ScoreEntry.current.where(participation: @participation).pluck(:id)
  end

  test "a correction without a reason is refused" do
    first = add_score(@participation, 60)
    assert_raises(ActiveRecord::RecordInvalid) { add_score(@participation, 64, supersedes: first) }
  end

  test "the same entry cannot be superseded twice (two corrections racing)" do
    first = add_score(@participation, 60)
    add_score(@participation, 64, supersedes: first, reason: "first correction")
    assert_raises(ActiveRecord::RecordNotUnique) do
      # Skip model validation to reproduce what a second concurrent request would do.
      ScoreEntry.new(participation: @participation, value: 66, entered_by_id: 2, entered_at: Time.current,
                     supersedes: first, correction_reason: "second correction").save!(validate: false)
    end
  end

  test "values outside 0..100 are refused" do
    assert_raises(ActiveRecord::RecordInvalid) { add_score(@participation, 101) }
  end
end
