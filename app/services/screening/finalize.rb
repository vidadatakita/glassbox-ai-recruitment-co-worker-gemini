module Screening
  # Writes the Decisions an AI result may produce WITHOUT a person: a pass that needs no review
  # (not an elimination, not unverified, not sampled, no calibration disagreement). Only when:
  #   - the S1 stage is open (D37: no decision on a draft stage), and
  #   - calibration has passed for the current rubric (D13: until then no AI result is final).
  # Every other result waits for the reviewer (Screening::Review). Idempotent: called after each
  # result, after each calibration judgement, and from the job page's "Mulai screening".
  #
  # Decision written: outcome pass, basis threshold, reason at_or_above_threshold, no person
  # (decided_by_id NULL), exactly what Scoring::Decider gives for the AI score at the stage's
  # current threshold. A later threshold change re-decides it like any threshold decision (rule 3).
  class Finalize
    def self.call(job) = new(job).call

    def initialize(job)
      @job = job
    end

    def call
      queue = ReviewQueue.new(@job)
      stage = queue.calibration.stage
      return 0 unless stage&.status == "open" && queue.calibration.passed?

      written = 0
      queue.automatic.each do |item|
        next unless item.outcome == :pass

        ActiveRecord::Base.transaction do
          participation = item.participation.lock!
          next if participation.current_decision

          Decision.create!(participation:, outcome: "pass", basis: "threshold", reason_code: "at_or_above_threshold",
                           decided_at: Time.current)
          written += 1
        end
      end
      written
    end
  end
end
