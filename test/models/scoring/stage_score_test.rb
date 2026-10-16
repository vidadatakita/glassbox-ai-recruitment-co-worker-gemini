require "test_helper"

class Scoring::StageScoreTest < ActiveSupport::TestCase
  test "a rating of 1 on every criterion is 0 and 5 on every criterion is 100" do
    assert_equal BigDecimal("0.0"), Scoring::StageScore.from_ratings([1, 1, 1])
    assert_equal BigDecimal("100.0"), Scoring::StageScore.from_ratings([5, 5])
  end

  test "mean rating 4 converts to 75" do
    assert_equal BigDecimal("75.0"), Scoring::StageScore.from_ratings([4, 4, 4])
  end

  test "a repeating result is rounded to one decimal" do
    # mean 11/3 -> (11/3 - 1) / 4 * 100 = 66.666...
    assert_equal BigDecimal("66.7"), Scoring::StageScore.from_ratings([3, 4, 4])
  end

  test "ratings outside 1..5, non-integers and empty lists are refused" do
    [[0], [6], [2.5], []].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} to be refused") do
        Scoring::StageScore.from_ratings(bad)
      end
    end
  end

  test "several interviewers are combined by their plain mean, rounded half up" do
    # (75.0 + 66.7) / 2 = 70.85 -> 70.9
    assert_equal BigDecimal("70.9"),
                 Scoring::StageScore.combine([BigDecimal("75.0"), BigDecimal("66.7")])
  end

  test "combining nothing is refused" do
    assert_raises(ArgumentError) { Scoring::StageScore.combine([]) }
  end
end
