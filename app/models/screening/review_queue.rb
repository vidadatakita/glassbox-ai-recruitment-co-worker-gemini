module Screening
  # What the reviewer must look at for one job, and what may become a decision without a person
  # (blueprint §4.1 step 8). Reads current, non-stale AI results of undecided S1 participations.
  #
  # Why a result needs a person, first reason wins:
  #   protected_attribute        the model reported a protected attribute in the text (ADR 0004)
  #   unverified                 a quote was not found in the CV (§4.1 step 6)
  #   calibration_disagreement   the consultant judged this CV differently during calibration
  #   elimination                the AI result eliminates (EVERY elimination is reviewed)
  #   sample                     a pass that fell in the reproducible 10% sample (ReviewSample)
  # A result with no reason is a pass that may be decided automatically, but only after
  # calibration has passed and only on an open stage (Screening::Finalize).
  class ReviewQueue
    Item = Data.define(:participation, :result, :reason, :outcome) do
      def needs_review? = !reason.nil?
    end

    attr_reader :calibration

    def initialize(job, calibration: Calibration.new(job))
      @job = job
      @calibration = calibration
    end

    def items
      return [] unless calibration.applicable?

      @items ||= begin
        stage = calibration.stage
        candidates = stage.participations.includes(job_application: :candidate).to_a
        results = ScreeningResult.current_for(candidates.map(&:id)).where(rubric_digest: calibration.digest)
                                 .index_by(&:participation_id)
        candidates.filter_map do |p|
          result = results[p.id]
          next if result.nil? || p.current_decision

          outcome = calibration.ai_outcome(result)
          Item.new(participation: p, result:, reason: reason_for(p, result, outcome), outcome:)
        end.sort_by { |i| [i.result.created_at, i.result.id] }
      end
    end

    def for_review = items.select(&:needs_review?)
    def automatic = items.reject(&:needs_review?)

    private

    def reason_for(participation, result, outcome)
      return "protected_attribute" if result.protected_attribute_categories.any?
      return "unverified" if result.unverified?
      return "calibration_disagreement" if calibration.disagreement_for(participation)
      return "elimination" if outcome == :eliminate
      return "sample" if result.sampled

      nil
    end
  end
end
