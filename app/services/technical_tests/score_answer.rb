module TechnicalTests
  # The reviewer scores one technical-test answer on the pinned version's rubric (D60 slice 5;
  # plan §c). One transaction writes: the ScoreEntry (append-only; value = RubricScore, ratings per
  # criterion), the Decision from Scoring::Decider with the S2 threshold (basis threshold, the
  # reviewer named), and the TestReview that links them with the note.
  #
  # Who: a user with role reviewer who is NOT the job's consultant (D60 16:45; the consultant is paid
  # by the job's progress, load-bearing-tests rule 19). Checked here and by two database triggers
  # (test_reviews_reviewer_not_consultant, score_entries_test_score_author).
  # When: S2 open (D37), the answer sent, no current S2 decision, and S1 NOT currently eliminated
  # (B-1: such a candidate gets gate_eliminated at close and is never scored). One score per answer;
  # a correction is not built (feature record, open items).
  class ScoreAnswer
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(attempt:, reviewer:, ratings:, note:, now: Time.current)
      @attempt = attempt
      @reviewer = reviewer
      @raw_ratings = ratings.to_h
      @note = note.to_s.strip.presence
      @now = now
      @participation = attempt.participation
      @stage = @participation.stage
      @job = @stage.job
    end

    def call
      refuse!("Only a reviewer can score the technical test.") unless @reviewer.role.in?(%w[hr_manager superadmin])
      refuse!("The reviewer must not be the consultant of this vacancy.") if @job.consultant_id.present? && @job.consultant_id == @reviewer.id

      ActiveRecord::Base.transaction do
        @participation.lock!
        check_state!
        criteria = @attempt.test_case.criteria.to_a
        ratings = parse_ratings(criteria)
        refuse!("The scoring note is required.") if @note.nil?

        entry = ScoreEntry.create!(participation: @participation, value: RubricScore.call(criteria, ratings),
                                   ratings: ratings.transform_keys(&:to_s), entered_by_id: @reviewer.id,
                                   event_at: @attempt.answered_at, entered_at: @now)
        decision = decide!
        TestReview.create!(participation: @participation, test_attempt: @attempt, reviewer: @reviewer, score_entry: entry,
                           decision:, ratings: entry.ratings, note: @note, created_at: @now)
      end
    end

    private

    def check_state!
      refuse!("The CV screening and technical test stage is not open yet. Scores can be recorded once the stage is open.") if @stage.status == "draft"
      refuse!("The CV screening and technical test stage is closed.") if @stage.status == "closed"
      refuse!("This candidate has not sent an answer.") unless @attempt.answered_at
      refuse!("This candidate did not pass CV screening; the technical test is not scored.") if TechnicalTests.s1_eliminated?(@participation.job_application)
      refuse!("This answer has already been scored.") if @participation.current_decision || @participation.score_entries.current.exists?
    end

    # Every criterion of the pinned version rated with a whole number 1-5; nothing else accepted.
    def parse_ratings(criteria)
      criteria.to_h do |criterion|
        value = Integer(@raw_ratings[criterion.id.to_s].to_s, exception: false)
        refuse!("Give a rating of 1 to 5 for every criterion.") unless value && Scoring::StageScore::RATING_RANGE.cover?(value)

        [criterion.id, value]
      end
    end

    def decide!
      result = Scoring::Decider.decide(score: @participation.current_score, threshold: @stage.threshold,
                                       attendance: @participation.attendance.to_sym,
                                       review_below_threshold: @stage.review_below_threshold)
      Decision.create!(participation: @participation, outcome: result.outcome.to_s, basis: result.basis.to_s,
                       reason_code: result.reason_code, decided_by_id: @reviewer.id, decided_at: @now)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
