# frozen_string_literal: true

module Scoring
  # Turns one participation's stage result into a decision (blueprint §2.2 rules 2, 5, 13, 16).
  #
  # basis :rule    - decided by a fact, not by the score: knockout, no-show, withdrawal.
  #                  A later threshold change never re-decides these (rule 3).
  # basis :threshold - decided by comparing the score with the stage threshold.
  module Decider
    Result = Data.define(:outcome, :basis, :reason_code)
    ATTENDANCE = %i[pending attended no_show withdrew].freeze

    module_function

    def decide(score:, threshold:, attendance: :attended, knockout_failed: false, review_below_threshold: false)
      raise ArgumentError, "unknown attendance #{attendance.inspect}" unless ATTENDANCE.include?(attendance)
      return Result.new(:eliminate, :rule, "knockout") if knockout_failed
      return Result.new(:eliminate, :rule, "no_show") if attendance == :no_show
      return Result.new(:eliminate, :rule, "withdrew") if attendance == :withdrew
      raise ArgumentError, "attendance has not been recorded yet" if attendance == :pending
      raise ArgumentError, "an attended participation needs a score before it can be decided" if score.nil?
      # nil.to_r and "abc".to_r are both 0, so a missing threshold would pass everyone and a
      # garbled score would count as zero. Refuse both (test engine F-17; §4.3 no silent default).
      raise ArgumentError, "threshold must be numeric, got #{threshold.inspect}" unless threshold.is_a?(Numeric)
      raise ArgumentError, "score must be numeric, got #{score.inspect}" unless score.is_a?(Numeric)

      # Inclusive ON PURPOSE (D9): a score equal to the threshold passes. Changing >= to >
      # would silently eliminate every candidate who lands exactly on the line.
      return Result.new(:pass, :threshold, "at_or_above_threshold") if score.to_r >= threshold.to_r
      return Result.new(:review, :threshold, "below_threshold_review") if review_below_threshold

      Result.new(:eliminate, :threshold, "below_threshold")
    end
  end
end
