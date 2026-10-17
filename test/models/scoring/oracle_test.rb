require "test_helper"

# The example board published with the blueprint (blueprint version 9): 12 candidates, five stages.
# Expected values below were computed independently of this code. If a change to the
# scoring core moves any of them, the change is wrong until proven otherwise.
class Scoring::OracleTest < ActiveSupport::TestCase
  STAGES = %w[S1 S2 S3 S4 S5].freeze
  WEIGHTS = { "S1" => 10, "S2" => 20, "S3" => 20, "S4" => 20, "S5" => 30 }.freeze
  THRESHOLDS = { "S1" => 60, "S2" => 60, "S3" => 65, "S4" => 60, "S5" => 70 }.freeze

  # :no_show marks a candidate who did not attend that stage.
  SCORES = {
    "A" => { "S1" => 88, "S2" => 84, "S3" => 82, "S4" => 78, "S5" => 86 },
    "B" => { "S1" => 81, "S2" => 72, "S3" => 74, "S4" => 71, "S5" => 72 },
    "C" => { "S1" => 77, "S2" => 79, "S3" => 69, "S4" => 56 },
    "D" => { "S1" => 74, "S2" => 58 },
    "E" => { "S1" => 70, "S2" => 67, "S3" => 61 },
    "F" => { "S1" => 66, "S2" => 62, "S3" => 63, "S4" => 65, "S5" => 68 },
    "G" => { "S1" => 63, "S2" => 70, "S3" => 66, "S4" => 74, "S5" => 79 },
    "H" => { "S1" => 61, "S2" => :no_show },
    "I" => { "S1" => 55 }, "J" => { "S1" => 48 }, "K" => { "S1" => 42 }, "L" => { "S1" => 58 }
  }.freeze

  # The HR PIC passed F at S3 below the threshold, with a reason (rule 4).
  MANUAL_PASS = [["F", "S3"]].freeze

  def run_board
    entered = SCORES.keys
    board = {}
    STAGES.each do |stage|
      rows = {}
      entered.each do |name|
        raw = SCORES[name][stage]
        attendance = raw == :no_show ? :no_show : :attended
        score = raw == :no_show ? nil : raw
        result = Scoring::Decider.decide(score:, threshold: THRESHOLDS[stage], attendance:)
        outcome = MANUAL_PASS.include?([name, stage]) ? :pass : result.outcome
        rows[name] = Scoring::StageStats::Row.new(attendance:, score:, outcome:)
      end
      board[stage] = rows
      entered = rows.select { |_n, r| r.outcome == :pass }.keys
    end
    board
  end

  test "who enters each stage" do
    board = run_board
    assert_equal %w[A B C D E F G H I J K L], board["S1"].keys
    assert_equal %w[A B C D E F G H], board["S2"].keys
    assert_equal %w[A B C E F G], board["S3"].keys
    assert_equal %w[A B C F G], board["S4"].keys
    assert_equal %w[A B F G], board["S5"].keys
  end

  test "stage statistics match the published board" do
    expected = {
      "S1" => [12, 8, 4, 0, "65.25", "64.5"],
      "S2" => [8, 6, 1, 1, "70.2857", "70.0"],
      "S3" => [6, 5, 1, 0, "69.1667", "67.5"],
      "S4" => [5, 4, 1, 0, "68.8", "71.0"],
      "S5" => [4, 3, 1, 0, "76.25", "75.5"]
    }
    board = run_board
    expected.each do |stage, (n, passed, eliminated, no_shows, avg, med)|
      s = Scoring::StageStats.call(board[stage].values)
      assert_equal [n, passed, eliminated, no_shows], [s.participants, s.passed, s.eliminated, s.no_shows], stage
      assert_equal BigDecimal(avg), BigDecimal(s.average, 12).round(4), "#{stage} average"
      assert_equal BigDecimal(med), BigDecimal(s.median, 12).round(4), "#{stage} median"
    end
  end

  # The published board has NO candidate exactly on a threshold, so on its own it cannot see
  # rule D9 (score == threshold passes): the mutation run of 2026-10-10 changed >= to > and
  # this file stayed green. This case adds one candidate, M, at exactly 60 on S1 (threshold
  # 60). It does not change the published board above. Expected values by hand:
  # S1 sum 783 (board) + 60 = 843 over 13 candidates; M passes, so 9 pass and 4 are eliminated.
  test "a candidate exactly on the S1 threshold passes and is counted as passed (D9)" do
    s1 = SCORES.transform_values { |stages| stages["S1"] }.merge("M" => 60)
    rows = s1.map do |_name, score|
      result = Scoring::Decider.decide(score:, threshold: THRESHOLDS["S1"])
      Scoring::StageStats::Row.new(attendance: :attended, score:, outcome: result.outcome)
    end
    s = Scoring::StageStats.call(rows)
    assert_equal [13, 9, 4], [s.participants, s.passed, s.eliminated]
    assert_equal Rational(843, 13), s.average
  end

  test "cumulative score of every candidate after their last stage" do
    expected = {
      "A" => "83.4", "B" => "73.1", "C" => "69.2857", "D" => "63.3333", "E" => "65.2", "F" => "65.0",
      "G" => "72.0", "H" => "61.0", "I" => "55.0", "J" => "48.0", "K" => "42.0", "L" => "58.0"
    }
    expected.each do |name, value|
      scores = SCORES[name].transform_values { |v| v == :no_show ? nil : v }
      got = Scoring::Cumulative.call(scores, WEIGHTS)
      assert_equal BigDecimal(value), BigDecimal(got, 12).round(4), name
    end
  end
end
