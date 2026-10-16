require "test_helper"

class ParticipationTest < ActiveSupport::TestCase
  setup { @participation = create_participation(stage: create_stage) }

  test "two interviewers: the stage score is the mean of their CURRENT entries" do
    first = add_score(@participation, 60)                  # interviewer 1, later corrected
    add_score(@participation, 70)                          # interviewer 2
    add_score(@participation, 80, supersedes: first, reason: "interviewer 1 corrected")
    assert_equal BigDecimal("75.0"), @participation.current_score   # (80 + 70) / 2, never uses 60
  end

  test "no entries means no score" do
    assert_nil @participation.current_score
  end
end
