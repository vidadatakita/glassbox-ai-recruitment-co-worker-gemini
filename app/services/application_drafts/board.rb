module ApplicationDrafts
  # The HR Manager's view of a vacancy's three-step applications (slice C): each submitted applicant
  # with the provisional score (multiple choice + the written ratings available, HR's over the AI's),
  # the vacancy average of those scores, and whether the written answers must be confirmed by a person
  # (at or above the average) or may stand on the AI's ratings (below it; Vida 17 Oct 2026). The
  # average is taken over applicants whose score is complete, so it moves as applications arrive; a
  # result already recorded never moves with it.
  class Board
    Row = Data.define(:draft, :score, :needs_review, :recorded)

    def initialize(job)
      @job = job
    end

    def drafts = @drafts ||= ApplicationDraft.where(job_id: @job.id).where.not(submitted_at: nil)
                                             .includes(:answers, job_application: :candidate).order(:submitted_at).to_a

    def scores = @scores ||= drafts.to_h { |d| [d.id, Score.call(d)] }

    # Applicants eliminated at S1 are left out: they never reach the test result, and counting them
    # would move the line for everyone else.
    def average
      values = drafts.reject { |d| TechnicalTests.s1_eliminated?(d.job_application) }.filter_map { |d| scores[d.id].value }
      values.empty? ? nil : (values.sum / values.size).round(2)
    end

    def below_average?(draft)
      value = Score.call(draft).value
      !value.nil? && !average.nil? && value < average
    end

    def rows
      drafts.map do |d|
        score = scores[d.id]
        participation = TechnicalTests.participation_for(d.job_application)
        recorded = participation&.current_decision.present?
        # A person confirms when an answer has no usable AI rating (failed, unverified quote, injection
        # attempt), or when the applicant is at or above the average and wrote something.
        needs = score.human_needed? || (!score.value.nil? && !average.nil? && score.value >= average && score.written_count.positive?)
        Row.new(d, score, needs, recorded)
      end
    end
  end
end
