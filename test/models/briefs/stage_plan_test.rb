require "test_helper"

# Stage sets per package (concept brief §3 ladder; RC in packages 4-5, blueprint §3.4), default
# weights (concept brief §4.1) re-normalised to 100, and rule 13 (S4 review for G1-3).
class Briefs::StagePlanTest < ActiveSupport::TestCase
  test "each package runs the stages of the concept-brief ladder" do
    assert_equal %w[S5], Briefs::StagePlan.codes(1)
    assert_equal %w[S1 S5], Briefs::StagePlan.codes(2)
    assert_equal %w[S1 S2 S3 S5], Briefs::StagePlan.codes(3)
    assert_equal %w[S1 S2 S3 S4 S5 RC], Briefs::StagePlan.codes(4)
    assert_equal %w[S1 S2 S3 S4 S5 RC], Briefs::StagePlan.codes(5)
  end

  test "default weights sum to exactly 100 for every package and RC carries none" do
    (1..5).each do |package|
      weights = Briefs::StagePlan.default_weights(package)
      assert_equal 100, weights.values.sum, "package #{package}"
      refute weights.key?("RC"), "RC has no score (rule 12)"
    end
  end

  test "default weights follow 10/20/20/20/30 re-normalised (package 3: 12.5/25/25/37.5 rounded)" do
    assert_equal({ "S1" => 10, "S2" => 20, "S3" => 20, "S4" => 20, "S5" => 30 }, Briefs::StagePlan.default_weights(4))
    assert_equal({ "S1" => 25, "S5" => 75 }, Briefs::StagePlan.default_weights(2))
    assert_equal({ "S1" => 13, "S2" => 25, "S3" => 25, "S5" => 37 }, Briefs::StagePlan.default_weights(3))
    assert_equal({ "S5" => 100 }, Briefs::StagePlan.default_weights(1))
  end

  test "S4 goes to review below threshold for G1-3 only (rule 13, D12)" do
    (1..3).each { |g| assert Briefs::StagePlan.review_below_threshold?("S4", g), "G#{g}" }
    (4..8).each { |g| refute Briefs::StagePlan.review_below_threshold?("S4", g), "G#{g}" }
    refute Briefs::StagePlan.review_below_threshold?("S5", 2), "control: only S4"
  end
end
