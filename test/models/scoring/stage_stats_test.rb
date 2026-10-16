require "test_helper"

class Scoring::StageStatsTest < ActiveSupport::TestCase
  Row = Scoring::StageStats::Row

  # Stage 2 of the blueprint's example board: seven scored candidates and one no-show.
  def stage_two_rows
    [[84, :pass], [72, :pass], [79, :pass], [58, :eliminate],
     [67, :pass], [62, :pass], [70, :pass]].map { |s, o| Row.new(attendance: :attended, score: s, outcome: o) } +
      [Row.new(attendance: :no_show, score: nil, outcome: :eliminate)]
  end

  test "counts participants, passes, eliminations and no-shows separately" do
    s = Scoring::StageStats.call(stage_two_rows)
    assert_equal [8, 6, 1, 1, 0], [s.participants, s.passed, s.eliminated, s.no_shows, s.in_review]
  end

  test "average and median use only candidates who completed the stage (rule 5)" do
    s = Scoring::StageStats.call(stage_two_rows)
    assert_equal Rational(492, 7), s.average   # 70.2857...
    assert_equal 70, s.median
    refute_equal Rational(492, 8), s.average, "a no-show must never be averaged in as zero"
  end

  test "median of an even count is the mean of the two middle scores" do
    rows = [82, 74, 69, 61, 63, 66].map { |x| Row.new(attendance: :attended, score: x, outcome: :pass) }
    assert_equal Rational(135, 2), Scoring::StageStats.call(rows).median   # 67.5
  end

  test "rows in review are counted as in review, not as passed or eliminated" do
    rows = [Row.new(attendance: :attended, score: 55, outcome: :review)]
    s = Scoring::StageStats.call(rows)
    assert_equal [0, 0, 1], [s.passed, s.eliminated, s.in_review]
  end

  test "a stage with nobody scored has no average and no median" do
    s = Scoring::StageStats.call([Row.new(attendance: :no_show, score: nil, outcome: :eliminate)])
    assert_nil s.average
    assert_nil s.median
  end
end
