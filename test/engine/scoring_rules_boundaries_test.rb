require "test_helper"

# Test engine, feature 01 (scoring core). Boundary tests for the plain-Ruby rules in
# app/models/scoring/. Every expected value here is computed by hand in the comment beside it,
# never by calling the code under test. Spec: blueprint §2.2 rules 1, 2, 5, 6, 9, 13, 16.
class EngineScoringRulesBoundariesTest < ActiveSupport::TestCase
  D = Scoring::Decider
  S = Scoring::StageScore
  Row = Scoring::StageStats::Row

  # ---- Rule 1: scale and rounding -------------------------------------------------------

  test "rule 1: (mean rating - 1) / 4 * 100 at every whole mean" do
    # mean 1 -> 0, 2 -> 25, 3 -> 50, 4 -> 75, 5 -> 100
    assert_equal [BigDecimal("0"), BigDecimal("25"), BigDecimal("50"), BigDecimal("75"), BigDecimal("100")],
                 (1..5).map { |r| S.from_ratings([r]) }
  end

  test "rule 1: an exact .x5 from ratings rounds half UP" do
    # [1,2] mean 1.5 -> 0.5/4*100 = 12.5 (already one decimal)
    assert_equal BigDecimal("12.5"), S.from_ratings([1, 2])
    # [1,1,1,1,1,1,1,2] mean 9/8 -> (1/8)/4*100 = 3.125 -> 3.1 (second decimal 2, rounds down)
    assert_equal BigDecimal("3.1"), S.from_ratings([1, 1, 1, 1, 1, 1, 1, 2])
    # 39 ones and one 2: mean 41/40 -> (1/40)/4*100 = 0.625 -> 0.6 (only the second decimal decides)
    assert_equal BigDecimal("0.6"), S.from_ratings([1] * 39 + [2])
    # 19 ones and one 2: mean 21/20 -> (1/20)/4*100 = 1.25 -> 1.3 (exact half, rounds up)
    assert_equal BigDecimal("1.3"), S.from_ratings([1] * 19 + [2])
  end

  test "rule 1: a value just below .x5 rounds DOWN" do
    # [3,3,4] mean 10/3 -> (7/3)/4*100 = 58.333... -> 58.3
    assert_equal BigDecimal("58.3"), S.from_ratings([3, 3, 4])
  end

  test "rule 1: combining interviewers - exact .x5 rounds half up, Rational not float" do
    # (66.7 + 70.0) / 2 = 68.35 -> 68.4
    assert_equal BigDecimal("68.4"), S.combine([BigDecimal("66.7"), BigDecimal("70.0")])
    # (0.0 + 0.1) / 2 = 0.05 -> 0.1
    assert_equal BigDecimal("0.1"), S.combine([BigDecimal("0.0"), BigDecimal("0.1")])
    # three interviewers 70.0, 70.0, 70.1 -> 210.1/3 = 70.0333 -> 70.0
    assert_equal BigDecimal("70.0"), S.combine([BigDecimal("70.0"), BigDecimal("70.0"), BigDecimal("70.1")])
  end

  test "rule 1: a Float input at .x5 still rounds half up (70.85 as a float is 70.8499...)" do
    # The float literal 70.85 is stored as 70.849999999999994315658... A naive Float#round(1)
    # gives 70.8. The spec value is 70.85 -> 70.9.
    assert_equal BigDecimal("70.9"), S.combine([70.85])
    assert_equal BigDecimal("0.2"), S.combine([0.15])
  end

  test "rule 1: combine refuses nothing, and from_ratings refuses negative, zero, 6, float, string" do
    assert_raises(ArgumentError) { S.combine([]) }
    [[-1], [0], [6], [4.0], ["4"], [nil]].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} refused") { S.from_ratings(bad) }
    end
  end

  test "rule 1: combined stage score stays inside 0..100 at the extremes" do
    assert_equal BigDecimal("100.0"), S.combine([BigDecimal("100.0"), BigDecimal("100.0")])
    assert_equal BigDecimal("0.0"), S.combine([BigDecimal("0.0")])
  end

  # ---- Rule 2: inclusive pass -------------------------------------------------------------

  test "rule 2: exactly at threshold passes, one tenth below eliminates, one tenth above passes" do
    assert_equal :pass, D.decide(score: BigDecimal("65.0"), threshold: BigDecimal("65.0")).outcome
    assert_equal :eliminate, D.decide(score: BigDecimal("64.9"), threshold: BigDecimal("65.0")).outcome
    assert_equal :pass, D.decide(score: BigDecimal("65.1"), threshold: BigDecimal("65.0")).outcome
  end

  test "rule 2: thresholds 0 and 100" do
    assert_equal :pass, D.decide(score: BigDecimal("0.0"), threshold: 0).outcome
    assert_equal :pass, D.decide(score: BigDecimal("100.0"), threshold: 100).outcome
    assert_equal :eliminate, D.decide(score: BigDecimal("99.9"), threshold: 100).outcome
  end

  test "rule 2: mixed Integer / BigDecimal / Rational / Float at the boundary compare exactly" do
    assert_equal :pass, D.decide(score: Rational(131, 2), threshold: BigDecimal("65.5")).outcome
    assert_equal :pass, D.decide(score: 65, threshold: BigDecimal("65.0")).outcome
    # Float 64.9 must not slip over a 65 line, and Float 65.0 must not fall under it.
    assert_equal :eliminate, D.decide(score: 64.9, threshold: 65).outcome
    assert_equal :pass, D.decide(score: 65.0, threshold: 65).outcome
  end

  test "FINDING-candidate: a nil threshold must not silently pass everyone" do
    # nil.to_r is 0 in Ruby, so a missing threshold would become 0 and pass every score.
    # A decision rule must refuse a missing threshold rather than default it (§4.3: never a
    # default score / silent default).
    assert_raises(ArgumentError, TypeError, NoMethodError) do
      D.decide(score: BigDecimal("10.0"), threshold: nil)
    end
  end

  test "FINDING-candidate: a non-numeric score string must not be read as zero" do
    # "abc".to_r is 0. A garbage score reaching the decider must be refused, not decided.
    assert_raises(ArgumentError, TypeError, NoMethodError) do
      D.decide(score: "abc", threshold: 0)
    end
  end

  test "rule 5/16 precedence: knockout beats no-show; no-show beats a score; withdrew beats a score" do
    r = D.decide(score: nil, threshold: 60, attendance: :no_show, knockout_failed: true)
    assert_equal [:eliminate, :rule, "knockout"], [r.outcome, r.basis, r.reason_code]
    r = D.decide(score: 99, threshold: 60, attendance: :no_show)
    assert_equal [:eliminate, :rule, "no_show"], [r.outcome, r.basis, r.reason_code]
    r = D.decide(score: 99, threshold: 60, attendance: :withdrew)
    assert_equal [:eliminate, :rule, "withdrew"], [r.outcome, r.basis, r.reason_code]
  end

  test "rule 13: review only below threshold; exactly at threshold passes; knockout still eliminates" do
    assert_equal :review, D.decide(score: BigDecimal("59.9"), threshold: 60, review_below_threshold: true).outcome
    assert_equal :pass, D.decide(score: BigDecimal("60.0"), threshold: 60, review_below_threshold: true).outcome
    r = D.decide(score: 10, threshold: 60, review_below_threshold: true, knockout_failed: true)
    assert_equal [:eliminate, :rule], [r.outcome, r.basis]
    r = D.decide(score: nil, threshold: 60, review_below_threshold: true, attendance: :no_show)
    assert_equal [:eliminate, :rule], [r.outcome, r.basis]
  end

  test "unknown attendance strings are refused (the model stores strings, the decider wants symbols)" do
    assert_raises(ArgumentError) { D.decide(score: 70, threshold: 60, attendance: "attended") }
    assert_raises(ArgumentError) { D.decide(score: 70, threshold: 60, attendance: :late) }
  end

  # ---- Rule 5 and 9: statistics -----------------------------------------------------------

  test "rule 5: no-show and withdrew never enter average or median" do
    rows = [Row.new(attendance: :attended, score: 80, outcome: :pass),
            Row.new(attendance: :attended, score: 60, outcome: :pass),
            Row.new(attendance: :no_show, score: nil, outcome: :eliminate),
            Row.new(attendance: :withdrew, score: nil, outcome: :eliminate)]
    s = Scoring::StageStats.call(rows)
    assert_equal 70, s.average   # (80 + 60) / 2
    assert_equal 70, s.median
    assert_equal 1, s.no_shows
    assert_equal 4, s.participants
  end

  test "rule 5: a no-show row that somehow carries a score is still not averaged" do
    rows = [Row.new(attendance: :attended, score: 80, outcome: :pass),
            Row.new(attendance: :no_show, score: 0, outcome: :eliminate)]
    assert_equal 80, Scoring::StageStats.call(rows).average
  end

  test "rule 9 tie-out: every participant lands in exactly one bucket" do
    # Rule 20 form (load-bearing-tests): the buckets must add up to the participant count.
    # A withdrawal is an elimination by rule (Decider) - it must be counted somewhere.
    rows = [Row.new(attendance: :attended, score: 80, outcome: :pass),
            Row.new(attendance: :attended, score: 40, outcome: :eliminate),
            Row.new(attendance: :attended, score: 55, outcome: :review),
            Row.new(attendance: :no_show, score: nil, outcome: :eliminate),
            Row.new(attendance: :withdrew, score: nil, outcome: :eliminate)]
    s = Scoring::StageStats.call(rows)
    assert_equal s.participants, s.passed + s.eliminated + s.no_shows + s.in_review,
                 "buckets #{[s.passed, s.eliminated, s.no_shows, s.in_review].inspect} vs participants #{s.participants}: " \
                 "a withdrawn candidate is in no bucket"
  end

  test "rule 5: the median through call() of two Integer scores keeps the .5" do
    rows = [70, 71].map { |x| Row.new(attendance: :attended, score: x, outcome: :pass) }
    assert_equal Rational(141, 2), Scoring::StageStats.call(rows).median   # 70.5, exact
    assert_equal 70, Scoring::StageStats.median([70])
  end

  test "FINDING-candidate (low): StageStats.median called directly with Integers truncates 70.5 to 70" do
    # median is a public module_function. (70 + 71) / 2 in Integer arithmetic is 70.
    # Only call() converts to Rational first; a scoreboard calling median directly gets 70.
    assert_equal Rational(141, 2), Scoring::StageStats.median([70, 71])
  end

  # ---- Rule 6: cumulative -----------------------------------------------------------------

  test "rule 6: renormalisation is exact Rational, not float" do
    # S1 w10 = 61, S2 w20 = 62 -> (610 + 1240) / 30 = 1850/30 = 61.666... exactly 185/3
    assert_equal Rational(185, 3), Scoring::Cumulative.call({ "S1" => 61, "S2" => 62 }, { "S1" => 10, "S2" => 20 })
  end

  test "rule 6: a zero-weight stage with a score does not move the cumulative" do
    # S1 w0 = 10, S2 w20 = 80 -> (0 + 1600) / 20 = 80
    assert_equal 80, Scoring::Cumulative.call({ "S1" => 10, "S2" => 80 }, { "S1" => 0, "S2" => 20 })
  end

  test "rule 6: all scored stages at weight zero is refused, not divided by zero" do
    assert_raises(ArgumentError) { Scoring::Cumulative.call({ "S1" => 70 }, { "S1" => 0 }) }
  end

  test "rule 6: a score of 0 is a score (left in), nil is not (left out)" do
    # S1 w10 = 0, S2 w10 = 80 -> 40 ; S1 nil -> 80
    assert_equal 40, Scoring::Cumulative.call({ "S1" => 0, "S2" => 80 }, { "S1" => 10, "S2" => 10 })
    assert_equal 80, Scoring::Cumulative.call({ "S1" => nil, "S2" => 80 }, { "S1" => 10, "S2" => 10 })
  end

  test "rule 6: BigDecimal stage scores keep exactness" do
    # (10*70.1 + 30*65.3) / 40 = (701 + 1959) / 40 = 2660/40 = 66.5
    assert_equal Rational(133, 2),
                 Scoring::Cumulative.call({ "S1" => BigDecimal("70.1"), "S2" => BigDecimal("65.3") },
                                          { "S1" => 10, "S2" => 30 })
  end
end
