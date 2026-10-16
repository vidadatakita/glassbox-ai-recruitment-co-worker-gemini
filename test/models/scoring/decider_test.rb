require "test_helper"

class Scoring::DeciderTest < ActiveSupport::TestCase
  def decide(**kw) = Scoring::Decider.decide(**kw)

  test "a score equal to the threshold passes (D9)" do
    r = decide(score: BigDecimal("65.0"), threshold: BigDecimal("65.0"))
    assert_equal [:pass, :threshold], [r.outcome, r.basis]
  end

  test "a score just below the threshold is eliminated" do
    r = decide(score: BigDecimal("64.9"), threshold: 65)
    assert_equal [:eliminate, :threshold, "below_threshold"], [r.outcome, r.basis, r.reason_code]
  end

  test "a no-show is eliminated by rule, not by threshold, and needs no score (rule 5)" do
    r = decide(score: nil, threshold: 60, attendance: :no_show)
    assert_equal [:eliminate, :rule, "no_show"], [r.outcome, r.basis, r.reason_code]
  end

  test "a withdrawal is eliminated by rule" do
    r = decide(score: nil, threshold: 60, attendance: :withdrew)
    assert_equal [:eliminate, :rule, "withdrew"], [r.outcome, r.basis, r.reason_code]
  end

  test "a failed knockout answer eliminates even a high score (rule 16)" do
    r = decide(score: 99, threshold: 60, knockout_failed: true)
    assert_equal [:eliminate, :rule, "knockout"], [r.outcome, r.basis, r.reason_code]
  end

  test "below threshold on a staff-level psychological test goes to review, not elimination (rule 13, D12)" do
    r = decide(score: 55, threshold: 60, review_below_threshold: true)
    assert_equal [:review, :threshold, "below_threshold_review"], [r.outcome, r.basis, r.reason_code]
  end

  test "review mode still passes a score at or above the threshold" do
    assert_equal :pass, decide(score: 60, threshold: 60, review_below_threshold: true).outcome
  end

  test "an attended participation without a score cannot be decided" do
    assert_raises(ArgumentError) { decide(score: nil, threshold: 60) }
  end

  test "a participation whose attendance was never recorded cannot be decided" do
    assert_raises(ArgumentError) { decide(score: 80, threshold: 60, attendance: :pending) }
  end
end
