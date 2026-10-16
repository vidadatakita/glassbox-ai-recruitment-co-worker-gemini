module Screening
  # The reviewer confirms or reverses one AI result (blueprint §4.1 step 8; screen 8 "Review
  # Screening"). Each review writes, in ONE transaction, the Decision it stands for and the
  # append-only ScreeningReview that records who, why and when.
  #
  # Who: a user with the reviewer role who is NOT the job's consultant (§1.2: the consultant is
  # paid by the job's progress; rule 19, actor who benefits). Checked here and again by the
  # database trigger screening_reviews_reviewer_not_consultant.
  #
  # When: only on an open S1 stage (D37), only after calibration has passed (D13: before that no
  # AI result is final, and a reviewer's click on an uncalibrated result would make it final), and
  # only for a current result that is in the review queue and not yet decided.
  #
  # What is written:
  #   confirm  -> the AI's own outcome. Basis "rule" for a failed wajib (reason wajib_not_met),
  #               otherwise "threshold" exactly as Scoring::Decider gives it; decided_by = reviewer.
  #               For an UNVERIFIED result the AI's evidence could not be checked, so the reviewer's
  #               confirmation is their own judgement: basis "manual", a note is required.
  #   reverse  -> the opposite outcome, basis "manual" (rule 4: a reason is required and the
  #               decision shows as manual, with who and when).
  class Review
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(result:, reviewer:, verdict:, note: nil, now: Time.current)
      @result = result
      @reviewer = reviewer
      @verdict = verdict.to_s
      @note = note.to_s.strip.presence
      @now = now
      @participation = result.participation
      @job = @participation.stage.job
    end

    def call
      refuse!("Only a reviewer can review screening.") unless @reviewer.role == "reviewer"
      if @job.consultant_id.present? && @job.consultant_id == @reviewer.id
        refuse!("The reviewer cannot be the consultant of this vacancy.")
      end
      refuse!("Choose Follow AI advice or Reverse.") unless ScreeningReview::VERDICTS.key?(@verdict)

      ActiveRecord::Base.transaction do
        @participation.lock!
        queue = ReviewQueue.new(@job)
        refuse!("The CV screening stage is not open yet. Decisions can be recorded once the stage is open.") unless queue.calibration.stage&.status == "open"
        refuse!("Calibration has not passed. AI advice cannot become a decision yet.") unless queue.calibration.passed?
        item = queue.for_review.find { |i| i.result.id == @result.id }
        refuse!("This result is not awaiting review, has already been decided, or has been replaced by a newer result.") if item.nil?

        decision = Decision.create!(decision_attributes(item))
        ScreeningReview.create!(participation: @participation, screening_result: @result, reviewer: @reviewer,
                                verdict: @verdict, reason: item.reason, note: @note, decision:, created_at: @now)
        decision
      end
    end

    private

    def decision_attributes(item)
      base = { participation: @participation, decided_by_id: @reviewer.id, decided_at: @now }
      if @verdict == "reverse"
        refuse!("A reason is required to reverse the AI advice.") if @note.nil?
        opposite = item.outcome == :pass ? "eliminate" : "pass"
        return base.merge(outcome: opposite, basis: "manual", reason_code: "screening_review_reversed", note: @note)
      end

      # Unverified quote, or a protected attribute the model saw: the AI's evidence cannot be trusted
      # as is, so a confirmation is the reviewer's own judgement (manual, note required).
      if %w[unverified protected_attribute].include?(item.reason)
        refuse!("A note is required: this AI result needs your own check, so following it is your own judgement.") if @note.nil?
        return base.merge(outcome: item.outcome.to_s, basis: "manual", reason_code: "screening_review_confirmed", note: @note)
      end

      result = Score.outcome(wajib_met: @result.wajib_met, score: @result.score, threshold: @participation.stage.threshold)
      base.merge(outcome: result.outcome.to_s, basis: result.basis.to_s, reason_code: result.reason_code, note: @note)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
