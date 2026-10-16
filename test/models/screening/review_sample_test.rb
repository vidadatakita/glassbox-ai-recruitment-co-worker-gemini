require "test_helper"

# Blueprint §4.1 step 8: a random 10% of passes, reproducible and recorded.
class Screening::ReviewSampleTest < ActiveSupport::TestCase
  def sampled(seed, range) = range.select { |n| Screening::ReviewSample.sampled?(seed:, ordinal: n) }

  test "exactly one pass in every block of ten is sampled" do
    picks = sampled("seed-a", 1..1000)
    assert_equal 100, picks.size
    picks.each_slice(1) { |(n)| assert_equal 1, sampled("seed-a", (((n - 1) / 10 * 10) + 1)..(((n - 1) / 10 * 10) + 10)).size }
  end

  test "reproducible from the seed, and different seeds choose differently" do
    assert_equal sampled("seed-a", 1..200), sampled("seed-a", 1..200)
    refute_equal sampled("seed-a", 1..200), sampled("seed-b", 1..200)
  end

  test "the choice inside a block is not always the same position (not a fixed every-10th)" do
    positions = sampled("seed-a", 1..1000).map { |n| (n - 1) % 10 }.uniq
    assert_operator positions.size, :>, 3
  end

  test "a missing seed or ordinal is refused" do
    assert_raises(ArgumentError) { Screening::ReviewSample.sampled?(seed: "", ordinal: 1) }
    assert_raises(ArgumentError) { Screening::ReviewSample.sampled?(seed: "x", ordinal: 0) }
  end
end
