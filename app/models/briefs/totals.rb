# frozen_string_literal: true

module Briefs
  # "Sums to exactly 100" for activity shares, sebaiknya weights and stage weights. Whole numbers
  # only: a blank or a fraction is not silently read as 0 (the F-17 lesson in Scoring::Decider).
  module Totals
    module_function

    def hundred?(values)
      list = Array(values)
      list.any? && list.all? { |v| v.is_a?(Integer) && v >= 0 } && list.sum == 100
    end

    def threshold?(value) = value.is_a?(Numeric) && value >= 0 && value <= 100
  end
end
