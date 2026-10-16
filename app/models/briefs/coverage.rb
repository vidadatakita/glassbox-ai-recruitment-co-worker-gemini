# frozen_string_literal: true

module Briefs
  # Blueprint §2.3 coverage table and rule 17: the competence layers a job's competency map must
  # cover, by Golongan. Coverage, not weight (rule 18): a layer adds no score.
  #
  #   Layer | G1-2 | G3 | G4-5 | G6-8
  #   L1    |  x   | x  |  x   |  -
  #   L2    |  -   | x  |  x   |  x
  #   L3    |  -   | -  |  x   |  x
  #   L4    |  x   | x  |  x   |  -
  #   L5    |  -   | x  |  x   |  x
  #   I     |  x   | x  |  x   |  x
  module Coverage
    REQUIRED = {
      1 => %w[L1 L4 I], 2 => %w[L1 L4 I],
      3 => %w[L1 L2 L4 L5 I],
      4 => %w[L1 L2 L3 L4 L5 I], 5 => %w[L1 L2 L3 L4 L5 I],
      6 => %w[L2 L3 L5 I], 7 => %w[L2 L3 L5 I], 8 => %w[L2 L3 L5 I]
    }.freeze

    module_function

    def required(golongan) = REQUIRED.fetch(golongan) { raise ArgumentError, "grade must be 1-8, got #{golongan.inspect}" }

    # The required layers with no competency, in table order. Empty means covered.
    def missing(golongan, layers) = required(golongan) - Array(layers).uniq

    def message(golongan, layers)
      gaps = missing(golongan, layers)
      return if gaps.empty?

      names = gaps.map { |code| "#{code} #{Competency::LAYERS.fetch(code)}" }
      "The competency map does not yet cover layer #{names.to_sentence}, " \
        "which is required for G#{golongan}. Add at least one competency in that layer."
    end
  end
end
