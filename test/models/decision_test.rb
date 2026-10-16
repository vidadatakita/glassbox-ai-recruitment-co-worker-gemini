require "test_helper"

class DecisionTest < ActiveSupport::TestCase
  # Open stage and a score: since D37 and test-engine F-06 (2026-10-10), a threshold decision
  # needs an open stage and an attended participation with a current score.
  setup do
    @participation = create_participation(stage: create_open_stage)
    add_score(@participation, 62)
  end

  test "a second decision must supersede the current one" do
    first = decide!(@participation, outcome: "eliminate", reason_code: "below_threshold")
    assert_raises(ActiveRecord::RecordInvalid) { decide!(@participation, outcome: "pass") }
    second = decide!(@participation, outcome: "pass", basis: "manual", reason_code: "override",
                     note: "Pengalaman cabang relevan", supersedes: first)
    assert_equal second, @participation.current_decision
  end

  test "a manual decision needs a note (rule 4)" do
    assert_raises(ActiveRecord::RecordInvalid) do
      decide!(@participation, outcome: "pass", basis: "manual", reason_code: "override")
    end
  end
end
