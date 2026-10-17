module ApplicationDrafts
  # Writes the competency-test result of one three-step application into its S2 participation: a
  # ScoreEntry (the Score value) and a Decision by Scoring::Decider against the stage threshold, the
  # same records the case-test scoring writes (TechnicalTests::ScoreAnswer), so the gate, the step-9
  # decision and the report read it like any S2 result.
  #   review:  the HR Manager confirms each answered written question (ratings 1-5, a note); required
  #            for applicants at or above the vacancy average (Vida 17 Oct 2026);
  #   ai:      recorded by the HR Manager for an applicant BELOW the vacancy average, with the AI's
  #            ratings standing for the written answers (Vida's decision; ratings marked "ai").
  # Only an HR Manager or the superadmin, never the vacancy's consultant; only on an open stage, after
  # S1 passed, once.
  class RecordScore
    Refused = Class.new(StandardError)

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(draft:, reviewer:, mode:, ratings: {}, note: nil, now: Time.current)
      @draft = draft
      @reviewer = reviewer
      @mode = mode.to_s
      @ratings = ratings.to_h.transform_keys(&:to_s)
      @note = note.to_s.squish.presence
      @now = now
    end

    def call
      job = @draft.job
      refuse!("Only an HR Manager scores the competency test.") unless @reviewer&.role.in?(%w[hr_manager superadmin])
      refuse!("The HR Manager who scores must not be the consultant of this vacancy.") if job.consultant_id.present? && job.consultant_id == @reviewer.id
      refuse!("Unknown scoring mode.") unless %w[review ai].include?(@mode)

      ActiveRecord::Base.transaction do
        participation = TechnicalTests.participation_for(@draft.job_application)
        refuse!("This application has no technical-test stage.") if participation.nil?
        participation.lock!
        check_state!(participation)
        @mode == "review" ? confirm_written! : check_below_average!
        score = Score.call(@draft.reload)
        refuse!("Some written answers have no rating yet; rate them first.") unless score.complete?

        ScoreEntry.create!(participation:, value: score.value, ratings: ratings_record, entered_by_id: @reviewer.id,
                           event_at: @draft.submitted_at, entered_at: @now)
        result = Scoring::Decider.decide(score: participation.current_score, threshold: participation.stage.threshold,
                                         attendance: participation.attendance.to_sym,
                                         review_below_threshold: participation.stage.review_below_threshold)
        Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s, reason_code: result.reason_code,
                         decided_by_id: @reviewer.id, decided_at: @now)
        score
      end
    end

    private

    def check_state!(participation)
      stage = participation.stage
      refuse!("The CV screening and technical test stage is not open yet.") if stage.status == "draft"
      refuse!("The CV screening and technical test stage is closed.") if stage.status == "closed"
      refuse!("This applicant did not pass CV screening; the test is not scored.") if TechnicalTests.s1_eliminated?(@draft.job_application)
      refuse!("This test has already been scored.") if participation.current_decision || participation.score_entries.current.exists?
    end

    def confirm_written!
      written = @draft.answers.includes(:bank_question).select { |a| a.bank_question.written? && a.answer_text.present? }
      refuse!("The scoring note is required.") if @note.nil? && written.any?
      written.each do |answer|
        rating = Integer(@ratings[answer.id.to_s].to_s, exception: false)
        refuse!("Give a rating of 1 to 5 for every written answer.") unless rating&.between?(1, 5)

        answer.update!(review_rating: rating, reviewed_by_id: @reviewer.id, reviewed_at: @now)
      end
    end

    # "ai" records without a person's ratings. Allowed when there is nothing a person must confirm: no
    # answered written question (multiple choice only; F4), or a below-average applicant whose every AI
    # rating is usable (quote found, no steering attempt; F3).
    def check_below_average!
      score = Score.call(@draft)
      return if score.written_count.zero?

      refuse!("A written answer has no usable AI rating (AI failed, quote not found, or an attempt to steer the AI); rate it yourself.") if score.human_needed?
      board = Board.new(@draft.job)
      refuse!("This applicant is at or above the vacancy average; the HR Manager confirms the written answers.") unless board.below_average?(@draft)
    end

    def ratings_record
      { "basis" => @mode == "review" ? "hr_manager" : "ai_below_average", "note" => @note,
        "answers" => @draft.answers.map { |a| { "question" => a.bank_question_id, "correct" => a.correct, "ai" => a.ai_rating, "review" => a.review_rating } } }
    end

    def refuse!(message) = raise(Refused, message)
  end
end
