require "test_helper"

# Blueprint §2.3 coverage table and rule 17. The table is the oracle; each row is asserted from
# the spec text, not from the constant under test.
class Briefs::CoverageTest < ActiveSupport::TestCase
  SPEC = { # copied from BLUEPRINT-T1 §2.3, column by column
    1 => %w[L1 L4 I], 2 => %w[L1 L4 I], 3 => %w[L1 L2 L4 L5 I],
    4 => %w[L1 L2 L3 L4 L5 I], 5 => %w[L1 L2 L3 L4 L5 I],
    6 => %w[L2 L3 L5 I], 7 => %w[L2 L3 L5 I], 8 => %w[L2 L3 L5 I]
  }.freeze

  test "the required layers per Golongan match the §2.3 table" do
    SPEC.each { |golongan, layers| assert_equal layers.sort, Briefs::Coverage.required(golongan).sort, "G#{golongan}" }
  end

  test "a map covering every required layer has nothing missing; dropping one names exactly that layer" do
    SPEC.each do |golongan, layers|
      assert_empty Briefs::Coverage.missing(golongan, layers), "G#{golongan} control"
      layers.each do |dropped|
        assert_equal [dropped], Briefs::Coverage.missing(golongan, layers - [dropped]), "G#{golongan} without #{dropped}"
      end
    end
  end

  test "optional layers do not count as missing (G1-2 need no L2/L3/L5; G6-8 need no L1/L4)" do
    assert_empty Briefs::Coverage.missing(2, %w[L1 L4 I])
    assert_empty Briefs::Coverage.missing(7, %w[L2 L3 L5 I])
  end

  test "the refusal names the missing layer with its screen label" do
    message = Briefs::Coverage.message(6, %w[L2 L3 I])
    assert_includes message, "L5 Teaching"
    assert_includes message, "G6"
    assert_nil Briefs::Coverage.message(6, %w[L2 L3 L5 I]), "control: covered map has no message"
  end

  test "a Golongan outside 1-8 is refused, not treated as covered" do
    assert_raises(ArgumentError) { Briefs::Coverage.missing(9, []) }
  end
end
