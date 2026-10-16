# frozen_string_literal: true

module Scoring
  # Cumulative score (blueprint §2.2 rule 6): the weighted mean over the stages the
  # candidate HAS a score for, with weights re-normalised to 100%. A stage without a score
  # (not reached, or a no-show) is left out entirely - it is never counted as zero.
  #
  # Rankings built on this value compare only candidates at the same stage; a candidate
  # eliminated at S1 has a cumulative built from S1 alone (the boards in Plan 6 enforce that).
  module Cumulative
    module_function

    def call(stage_scores, weights)
      scored = stage_scores.reject { |_code, score| score.nil? }
      return nil if scored.empty?

      missing = scored.keys - weights.keys
      raise ArgumentError, "no weight for stage(s) #{missing.join(', ')}" if missing.any?

      total_weight = scored.keys.sum { |code| weights.fetch(code) }
      raise ArgumentError, "the weights of the scored stages sum to zero" if total_weight.zero?

      Rational(scored.sum { |code, score| weights.fetch(code) * score.to_r }, total_weight)
    end
  end
end
