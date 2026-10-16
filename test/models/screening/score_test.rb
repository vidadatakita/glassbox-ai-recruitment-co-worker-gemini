require "test_helper"

# Blueprint §4.1 steps 4-5: the score is computed in Ruby from the judgements. Formula (builder
# reading, feature record 06 §2): sum of weight x rating / 3 over sebaiknya; wajib not met ->
# eliminate by rule; nilai tambah display only.
class Screening::ScoreTest < ActiveSupport::TestCase
  Req = Struct.new(:id, :tier, :text, :cv_evidence, :weight, :position)

  def rubric
    Screening::Rubric.new([
      Req.new(1, "wajib", "D3", "Ijazah", nil, 1), Req.new(2, "sebaiknya", "Gudang", "Riwayat", 60, 2),
      Req.new(3, "sebaiknya", "Excel", "Keahlian", 40, 3), Req.new(4, "nilai_tambah", "SIM C", "SIM", nil, 4)
    ])
  end

  def judge(w: "met", a: "3", b: "3", bonus: "0")
    { "R1" => { "judgement" => w }, "R2" => { "judgement" => a }, "R3" => { "judgement" => b }, "R4" => { "judgement" => bonus } }
      .transform_values { |j| j.merge("verified" => true) }
  end

  def score(**kw) = Screening::Score.compute(rubric, judge(**kw))

  test "hand-computed oracle values" do
    assert_equal BigDecimal("100.0"), score.score
    assert_equal BigDecimal("0.0"), score(a: "0", b: "0").score
    # 60 x 2/3 + 40 x 1/3 = 40 + 13.333 = 53.3
    assert_equal BigDecimal("53.3"), score(a: "2", b: "1").score
    # 60 x 1/3 + 40 x 2/3 = 20 + 26.667 = 46.7 (half up)
    assert_equal BigDecimal("46.7"), score(a: "1", b: "2").score
  end

  test "identical judgements always give the identical score" do
    assert_equal Array.new(5) { score(a: "2", b: "1").to_h }.uniq.size, 1
  end

  test "nilai tambah never moves the score or the decision (display only)" do
    low = score(a: "1", b: "1", bonus: "0")
    high = score(a: "1", b: "1", bonus: "3")
    assert_equal low.score, high.score
    assert_equal [0, 3], [low.bonus_points, low.bonus_possible]
    assert_equal [3, 3], [high.bonus_points, high.bonus_possible]
    assert_equal Screening::Score.outcome(wajib_met: true, score: low.score, threshold: 50).to_h,
                 Screening::Score.outcome(wajib_met: true, score: high.score, threshold: 50).to_h
  end

  test "a wajib not met eliminates by rule whatever the score" do
    result = score(w: "not_met")
    assert_equal BigDecimal("100.0"), result.score
    refute result.wajib_met
    decision = Screening::Score.outcome(wajib_met: false, score: result.score, threshold: 60)
    assert_equal [:eliminate, :rule, "wajib_not_met"], [decision.outcome, decision.basis, decision.reason_code]
  end

  test "a score exactly at the threshold passes (D9, inclusive)" do
    decision = Screening::Score.outcome(wajib_met: true, score: BigDecimal("53.3"), threshold: BigDecimal("53.3"))
    assert_equal :pass, decision.outcome
    below = Screening::Score.outcome(wajib_met: true, score: BigDecimal("53.2"), threshold: BigDecimal("53.3"))
    assert_equal :eliminate, below.outcome
  end

  test "unverified criteria are counted" do
    j = judge
    j["R2"]["verified"] = false
    assert_equal 1, Screening::Score.compute(rubric, j).unverified_count
  end

  test "a missing judgement or a rating outside 0-3 is refused, never read as zero" do
    j = judge
    j.delete("R3")
    assert_raises(ArgumentError) { Screening::Score.compute(rubric, j) }
    assert_raises(ArgumentError) { score(a: "met") }
    assert_raises(ArgumentError) { score(a: "4") }
  end

  test "sebaiknya weights that do not sum to 100 are refused" do
    bad = Screening::Rubric.new([Req.new(2, "sebaiknya", "Gudang", "Riwayat", 50, 1)])
    assert_raises(ArgumentError) { Screening::Score.compute(bad, { "R2" => { "judgement" => "3", "verified" => true } }) }
  end
end
