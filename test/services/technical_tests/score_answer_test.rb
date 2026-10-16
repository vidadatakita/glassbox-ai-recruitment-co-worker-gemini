require "test_helper"

# D60 slice 5 (plan §c "Scoring (T1)"; D60 16:45 "scored by the Reviewer role, who is never the
# job's consultant"): the weighted rubric formula, the ScoreEntry + Decision + TestReview written
# together, and who may write them, in the service AND the database.
class TechnicalTests::ScoreAnswerTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  Criterion = Struct.new(:id, :weight)

  setup do
    @job = technical_test_job
    @application, = applicant!(@job)
    @attempt = answered!(@application)
    @s2 = s2_of(@application)
  end

  # --- the formula -----------------------------------------------------------------------------

  test "rubric score: all 1 = 0.0, all 5 = 100.0, all 3 = 50.0" do
    criteria = [Criterion.new(1, 60), Criterion.new(2, 40)]
    assert_equal BigDecimal("0.0"), TechnicalTests::RubricScore.call(criteria, { 1 => 1, 2 => 1 })
    assert_equal BigDecimal("100.0"), TechnicalTests::RubricScore.call(criteria, { 1 => 5, 2 => 5 })
    assert_equal BigDecimal("50.0"), TechnicalTests::RubricScore.call(criteria, { 1 => 3, 2 => 3 })
  end

  test "rubric score is WEIGHTED: 60/40 with 5/1 is 60.0, and 1/5 is 40.0 (unweighted would give 50.0 for both)" do
    criteria = [Criterion.new(1, 60), Criterion.new(2, 40)]
    assert_equal BigDecimal("60.0"), TechnicalTests::RubricScore.call(criteria, { 1 => 5, 2 => 1 })
    assert_equal BigDecimal("40.0"), TechnicalTests::RubricScore.call(criteria, { 1 => 1, 2 => 5 })
  end

  test "rubric score rounds half up to one decimal: weights 33/33/34 with 2/2/3" do
    # weighted mean = (66 + 66 + 102) / 100 = 2.34 -> (2.34 - 1) / 4 * 100 = 33.5
    criteria = [Criterion.new(1, 33), Criterion.new(2, 33), Criterion.new(3, 34)]
    assert_equal BigDecimal("33.5"), TechnicalTests::RubricScore.call(criteria, { 1 => 2, 2 => 2, 3 => 3 })
    # 1/1/2 with 33/33/34: mean 1.34 -> 8.5
    assert_equal BigDecimal("8.5"), TechnicalTests::RubricScore.call(criteria, { 1 => 1, 2 => 1, 3 => 2 })
  end

  test "rubric score refuses a missing or out-of-range rating and weights that do not sum to 100" do
    criteria = [Criterion.new(1, 60), Criterion.new(2, 40)]
    assert_raises(ArgumentError) { TechnicalTests::RubricScore.call(criteria, { 1 => 5 }) }
    assert_raises(ArgumentError) { TechnicalTests::RubricScore.call(criteria, { 1 => 6, 2 => 1 }) }
    assert_raises(ArgumentError) { TechnicalTests::RubricScore.call(criteria, { 1 => 0, 2 => 1 }) }
    assert_raises(ArgumentError) { TechnicalTests::RubricScore.call([Criterion.new(1, 60)], { 1 => 3 }) }
  end

  # --- the service -----------------------------------------------------------------------------

  test "a reviewer's scoring writes the score entry, the threshold decision and the review together" do
    review = TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 1]),
                                              note: "Selisih utama ditemukan, koreksi kurang.")
    entry = review.score_entry
    assert_equal BigDecimal("60.0"), entry.value
    assert_equal reviewer.id, entry.entered_by_id
    assert_equal ratings_for(@attempt, [5, 1]).transform_values(&:to_i), entry.ratings
    decision = @s2.reload.current_decision
    assert_equal review.decision, decision
    # The briefed job's S2 threshold is 60: a score exactly on the line passes (D9, inclusive).
    assert_equal BigDecimal("60.0"), @s2.stage.threshold
    assert_equal %w[pass threshold at_or_above_threshold], [decision.outcome, decision.basis, decision.reason_code]
    assert_equal reviewer.id, decision.decided_by_id
  end

  test "below the S2 threshold the decision is an elimination by threshold" do
    TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [3, 3]), note: "Cukup.")
    decision = @s2.reload.current_decision
    assert_equal BigDecimal("50.0"), @s2.current_score # (0.6*3 + 0.4*3 - 1) / 4 * 100 = 50.0, below 60
    assert_equal %w[eliminate threshold below_threshold], [decision.outcome, decision.basis, decision.reason_code]
  end

  test "the job's consultant and non-reviewers are refused, and nothing is written" do
    consultant = User.find(@job.consultant_id)
    error = assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: consultant, ratings: ratings_for(@attempt, [5, 5]), note: "x")
    end
    assert_match "Only a reviewer", error.message
    assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: staff_user("hr_pic"), ratings: ratings_for(@attempt, [5, 5]), note: "x")
    end
    assert_empty @s2.score_entries
  end

  test "a reviewer who is the job's consultant is refused by the service" do
    @job.update!(consultant_id: reviewer.id)
    error = assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 5]), note: "x")
    end
    assert_match "consultant of this vacancy", error.message
  end

  test "the database refuses a score on an answered test by the job's consultant, even as a reviewer" do
    @job.update!(consultant_id: reviewer.id)
    error = refused_by_database do
      ScoreEntry.create!(participation: @s2, value: 80, entered_by_id: reviewer.id, entered_at: Time.current)
    end
    assert_match "scored by a reviewer who is not the job's consultant", error.message
    other = staff_user("consultant", email: "konsultan.lain@uji.example")
    refused_by_database { ScoreEntry.create!(participation: @s2, value: 80, entered_by_id: other.id, entered_at: Time.current) }
  end

  test "the database refuses a test review by a consultant or with another participation's score" do
    entry = ScoreEntry.create!(participation: @s2, value: 80, entered_by_id: reviewer.id, entered_at: Time.current)
    decision = Decision.create!(participation: @s2, outcome: "pass", basis: "threshold", reason_code: "at_or_above_threshold", decided_at: Time.current)
    @job.update!(consultant_id: reviewer.id)
    error = refused_by_database do
      TestReview.create!(participation: @s2, test_attempt: @attempt, reviewer:, score_entry: entry, decision:, ratings: {}, created_at: Time.current)
    end
    assert_match "the reviewer is the job's consultant", error.message
  end

  test "control: the narrow score guard leaves a gated S2 without an answer to the scoring core" do
    other, = applicant!(@job)
    s2 = s2_of(other)
    s2.update!(attendance: "attended")
    assert ScoreEntry.create!(participation: s2, value: 70, entered_by_id: staff_user("consultant").id, entered_at: Time.current).persisted?
  end

  test "test reviews are append-only" do
    review = TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [4, 4]), note: "Baik.")
    error = refused_by_database { TestReview.where(id: review.id).update_all(note: "diubah") }
    assert_match "append-only", error.message
  end

  test "S1 currently eliminated: refused (gate_eliminated at close), and the queue leaves the answer out" do
    s1 = s1_of(@application)
    s1.update!(attendance: "attended")
    add_score(s1, 10)
    decide!(s1, outcome: "eliminate", reason_code: "below_threshold")
    error = assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 5]), note: "x")
    end
    assert_match "did not pass CV screening", error.message
    board = TestScoringBoard.new(@job)
    assert_empty board.to_score
    assert_equal [@attempt.id], board.excluded.map { |row| row.attempt.id }
  end

  test "control: the queue lists an answered candidate whose S1 is not eliminated" do
    assert_equal [@attempt.id], TestScoringBoard.new(@job).to_score.map { |row| row.attempt.id }
  end

  test "a second scoring is refused; a missing rating or note is refused; a draft gate is refused" do
    assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5]), note: "x")
    end
    assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 5]), note: " ")
    end
    TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 5]), note: "Sangat baik.")
    error = assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer(email: "reviewer2@uji.example"), ratings: ratings_for(@attempt, [1, 1]), note: "x")
    end
    assert_match "already been scored", error.message
    assert_equal 1, @s2.score_entries.count

    draft_job = technical_test_job(open_gate: false)
    draft_app, = applicant!(draft_job)
    draft_attempt = answered!(draft_app)
    error = assert_raises(TechnicalTests::ScoreAnswer::Refused) do
      TechnicalTests::ScoreAnswer.call(attempt: draft_attempt, reviewer: reviewer, ratings: ratings_for(draft_attempt, [5, 5]), note: "x")
    end
    assert_match "not open yet", error.message
  end
end
