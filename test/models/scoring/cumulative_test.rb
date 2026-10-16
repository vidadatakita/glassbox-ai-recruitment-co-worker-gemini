require "test_helper"

class Scoring::CumulativeTest < ActiveSupport::TestCase
  WEIGHTS = { "S1" => 10, "S2" => 20, "S3" => 20, "S4" => 20, "S5" => 30 }.freeze

  test "weights re-normalise over the stages the candidate has a score for" do
    # (10*88 + 20*84 + 20*82) / 50 = 84
    assert_equal 84, Scoring::Cumulative.call({ "S1" => 88, "S2" => 84, "S3" => 82 }, WEIGHTS)
  end

  test "a stage without a score is left out, never counted as zero" do
    # Candidate H: no-show at S2 keeps the S1 score as the cumulative.
    assert_equal 61, Scoring::Cumulative.call({ "S1" => 61, "S2" => nil }, WEIGHTS)
  end

  test "all five stages" do
    # Candidate F: (660 + 1240 + 1260 + 1300 + 2040) / 100 = 65
    scores = { "S1" => 66, "S2" => 62, "S3" => 63, "S4" => 65, "S5" => 68 }
    assert_equal 65, Scoring::Cumulative.call(scores, WEIGHTS)
  end

  test "nothing scored gives no cumulative" do
    assert_nil Scoring::Cumulative.call({ "S1" => nil }, WEIGHTS)
  end

  test "a scored stage without a weight is refused" do
    assert_raises(ArgumentError) { Scoring::Cumulative.call({ "S9" => 70 }, WEIGHTS) }
  end
end
