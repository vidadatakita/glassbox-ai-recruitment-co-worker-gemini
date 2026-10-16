module Stages
  # Changes a stage's threshold (blueprint §2.2 rule 3).
  #
  # On a locked (opened) stage it writes a StageChange with the reason, updates the stage,
  # and re-decides every CURRENT threshold-based decision against the new threshold. Manual
  # decisions and rule decisions (no-show, withdrawal, knockout) are kept exactly as they
  # were. Everything happens in one transaction: a failure part-way changes nothing (§4.3).
  class ChangeThreshold
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(stage:, new_threshold:, reason:, actor_id:, now: Time.current)
      @stage = stage
      @new_threshold = new_threshold
      @reason = reason
      @actor_id = actor_id
      @now = now
    end

    def call
      raise ArgumentError, "a reason is required to change a threshold" if @reason.to_s.strip.empty?
      # D37 (2026-10-10): after close, a correction is a manual Decision with a reason; moving the
      # line would re-decide candidates who may already have their notice (test engine F-07).
      unless @new_threshold.is_a?(Numeric) && (0..100).cover?(@new_threshold)
        raise ArgumentError, "threshold must be a number from 0 to 100, got #{@new_threshold.inspect}"
      end
      # Read the status from the database, not from the caller's object: a stale object from
      # another tab may still say "open" after the stage closed (test engine F-19). Not lock!,
      # which raises on a caller's object that still holds an unsaved change. The database
      # refuses a closed-stage change as well (trigger stages_lifecycle).
      raise ArgumentError, "the stage is already closed" if Stage.where(id: @stage.id).pick(:status) == "closed"
      return draft_change unless @stage.locked?

      ActiveRecord::Base.transaction do
        change = StageChange.create!(stage: @stage, field: "threshold", old_value: @stage.threshold,
                                     new_value: @new_threshold, reason: @reason, changed_by_id: @actor_id, changed_at: @now)
        # Names the change for the stages_lifecycle trigger, which refuses a locked threshold edit
        # without a StageChange in this transaction (test engine F-04). true = transaction-local.
        ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(["SELECT set_config('glassbox.stage_change_id', ?, true)", change.id.to_s])
        )
        @stage.unlock_for_change { @stage.update!(threshold: @new_threshold) }
        @stage.participations.find_each { |participation| redecide(participation) }
      end
      @stage
    end

    private

    def draft_change
      @stage.update!(threshold: @new_threshold)
      @stage
    end

    def redecide(participation)
      current = participation.current_decision
      return unless current&.basis == "threshold"
      # D37 / rule 13: a review is cleared only by a person. Lowering the line never turns it into
      # a pass; it stays until someone decides (raising the line may still turn a pass into review).
      return if current.outcome == "review"

      result = Scoring::Decider.decide(score: participation.current_score, threshold: @stage.threshold,
                                       attendance: participation.attendance.to_sym,
                                       review_below_threshold: @stage.review_below_threshold)
      return if result.outcome.to_s == current.outcome

      Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s,
                       reason_code: result.reason_code, decided_by_id: @actor_id, decided_at: @now,
                       supersedes: current, note: "Re-decided after threshold change: #{@reason}")
    end
  end
end
