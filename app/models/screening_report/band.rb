module ScreeningReport
  # D62 h1: the S1 score is SHOWN as 1-5, STORED and DECIDED as 0-100. Equal bands of 20 points:
  # 0-19 = 1, 20-39 = 2, 40-59 = 3, 60-79 = 4, 80-100 = 5. Scores carry one decimal (feature 06),
  # so a band ends just below the next whole twenty: 19.9 is band 1, 20.0 is band 2. 100 is band 5.
  # The band is display only: no decision, sort or threshold ever reads it (the sort uses 0-100).
  module Band
    RULE = "Scale 1–5 from the 0–100 score: 0–19 = 1, 20–39 = 2, 40–59 = 3, 60–79 = 4, 80–100 = 5.".freeze

    module_function

    def of(score)
      return nil if score.nil?

      value = BigDecimal(score.to_s)
      raise ArgumentError, "S1 score outside 0-100: #{value}" unless value.between?(0, 100)

      [(value / 20).floor + 1, 5].min
    end
  end
end
