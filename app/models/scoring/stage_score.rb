# frozen_string_literal: true

module Scoring
  # Converts interview ratings into a stage score on the 0-100 scale (blueprint §2.2 rule 1).
  #
  # Ratings use a 1-5 scale. A 1 maps to 0 and a 5 maps to 100, so the conversion is
  # (mean rating - 1) / 4 * 100. Arithmetic is done in Rational so no float error reaches
  # a decision; the result keeps one decimal, rounded half up, because stage scores are
  # stored as decimal(4,1).
  module StageScore
    RATING_RANGE = (1..5)

    module_function

    # ratings: the ratings ONE interviewer gave, one per competency.
    def from_ratings(ratings)
      raise ArgumentError, "ratings must not be empty" if ratings.empty?
      unless ratings.all? { |r| r.is_a?(Integer) && RATING_RANGE.cover?(r) }
        raise ArgumentError, "every rating must be an integer from 1 to 5"
      end

      mean = Rational(ratings.sum, ratings.size)
      round1((mean - 1) / 4 * 100)
    end

    # scores: the stage scores of several interviewers for the SAME participation.
    def combine(scores)
      raise ArgumentError, "scores must not be empty" if scores.empty?

      round1(Rational(scores.sum(&:to_r), scores.size))
    end

    def round1(rational)
      BigDecimal(rational, 12).round(1, BigDecimal::ROUND_HALF_UP)
    end
  end
end
