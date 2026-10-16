module ScreeningReport
  # The optional "Gaji yang diharapkan (opsional)" on the Lamar data step (D62 h5): integer rupiah
  # per month, both ends or neither (database CHECK job_applications_expected_salary). Typed as
  # the candidate writes it ("7.500.000", "7500000", "Rp 7.500.000"): dots, spaces and a leading
  # "Rp" are formatting, anything else is refused. Never sent to the AI (Screening::Run reads only
  # the CV text), never part of a score.
  module ExpectedSalary
    # Storage guard only (bigint), not a business rule.
    MAX = 9_999_999_999
    Parsed = Data.define(:min, :max, :error)

    module_function

    def parse(raw_min, raw_max)
      min = number(raw_min)
      max = number(raw_max)
      return Parsed.new(min: nil, max: nil, error: nil) if raw_min.to_s.strip.empty? && raw_max.to_s.strip.empty?
      return refused("Enter both the minimum and the maximum salary, or leave both empty.") if min.nil? || max.nil?
      return refused("The salary must be more than Rp0.") unless min.positive? && max.positive?
      return refused("The salary is too large; check the figure.") if max > MAX
      return refused("The minimum salary cannot be more than the maximum.") if min > max

      Parsed.new(min:, max:, error: nil)
    end

    def refused(message) = Parsed.new(min: nil, max: nil, error: message)

    # Whole rupiah only: plain digits ("7500000"), or "." thousand separators in groups of three
    # ("7.500.000"); spaces between groups and a leading "Rp" are formatting. Anything else, notably a
    # decimal part ("6100000.5", "7.500.000,50"), is refused: deleting every "." used to read
    # "6100000.5" as 61.000.005 (engine 11 F-03). Shared by the Lamar field (feature 08) and the salary
    # agreement (feature 11).
    def number(raw)
      text = raw.to_s.strip.sub(/\ARp\.?\s*/i, "").delete(" ")
      return nil unless text.match?(/\A\d+\z/) || text.match?(/\A\d{1,3}(?:\.\d{3})+\z/)

      text.delete(".").to_i
    end
  end
end
