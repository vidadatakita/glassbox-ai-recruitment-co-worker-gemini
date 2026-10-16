require "test_helper"

# D53: criteria SHOWN on 1-5; the score and decisions stay on the original judgements.
class ScreeningReport::CriterionScaleTest < ActiveSupport::TestCase
  test "the D53 mapping, every value" do
    scale = ScreeningReport::CriterionScale
    assert_equal [5, 1], [scale.of("wajib", "met"), scale.of("wajib", "not_met")]
    %w[sebaiknya nilai_tambah].each do |tier|
      assert_equal [1, 2, 4, 5], %w[0 1 2 3].map { |j| scale.of(tier, j) }, tier
    end
  end

  test "an unknown judgement is refused, never shown as a silent number" do
    assert_raises(ArgumentError) { ScreeningReport::CriterionScale.of("sebaiknya", "4") }
    assert_raises(ArgumentError) { ScreeningReport::CriterionScale.of("wajib", "2") }
  end

  test "display only: the S1 score formula never reads the 1-5 scale" do
    refute_match(/CriterionScale/, File.read(Rails.root.join("app/models/screening/score.rb")))
    refute_match(/CriterionScale/, File.read(Rails.root.join("app/services/screening/run.rb")))
  end
end
