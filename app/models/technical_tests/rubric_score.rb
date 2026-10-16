module TechnicalTests
  # The S2 stage score from a reviewer's rubric ratings (plan §c "Scoring (T1)").
  #
  # Same scale as the existing scorecard (blueprint §2.2 rule 1, Scoring::StageScore): ratings are
  # 1-5, a 1 maps to 0 and a 5 maps to 100, score = (mean - 1) / 4 x 100, one decimal, half up.
  # The difference is the MEAN: here it is WEIGHTED by each criterion's weight (whole %, a version's
  # weights sum to exactly 100, enforced at approval), because the consultant set those weights to
  # say which activity matters more. Scoring::StageScore.from_ratings (unweighted) is deliberately
  # not used: with weights 60/40 and ratings 5/1 it would give 50.0, the weighted rubric gives 60.0.
  #
  #   weighted mean = sum(weight_i x rating_i) / sum(weight_i)
  #   score         = (weighted mean - 1) / 4 x 100        (Rational until the final rounding)
  module RubricScore
    module_function

    # criteria: the version's TestCaseCriterion rows. ratings: { criterion_id => Integer 1..5 }.
    def call(criteria, ratings)
      raise ArgumentError, "a rubric needs at least one criterion" if criteria.empty?

      total_weight = criteria.sum(&:weight)
      raise ArgumentError, "criterion weights must sum to 100, got #{total_weight}" unless total_weight == 100

      weighted = criteria.sum do |criterion|
        rating = ratings[criterion.id]
        unless rating.is_a?(Integer) && Scoring::StageScore::RATING_RANGE.cover?(rating)
          raise ArgumentError, "criterion #{criterion.id} needs an integer rating 1-5, got #{rating.inspect}"
        end

        criterion.weight * rating
      end
      mean = Rational(weighted, total_weight)
      Scoring::StageScore.round1((mean - 1) / 4 * 100)
    end
  end
end
