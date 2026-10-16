module ScreeningReport
  # "FIT: Budget" (D62 h5): the candidate's expected salary (optional Lamar field, integer rupiah
  # per month) compared IN CODE with the job's salary band (feature 03, integer rupiah per month,
  # gross). Information only: never sent to the AI, never part of any score or decision.
  #
  # Builder reading of "Di bawah / Dalam / Di atas rentang" for a RANGE against a RANGE:
  #   Di bawah rentang  the whole expected range is below the band   (expected_max < band_min)
  #   Di atas rentang   the whole expected range is above the band   (expected_min > band_max)
  #   Dalam rentang     the two ranges overlap, even partly (a negotiable fit)
  # Both ends are inclusive: an expected range ending exactly at band_min is "Dalam rentang".
  module Budget
    LABELS = {
      below: ["Below band", "info"], within: ["Within band", "success"], above: ["Above band", "warning"],
      not_given: ["Not given by applicant", "muted"], no_band: ["Vacancy salary band not set", "muted"]
    }.freeze

    module_function

    def fit(expected_min:, expected_max:, band_min:, band_max:)
      return :not_given if expected_min.nil? || expected_max.nil?
      return :no_band if band_min.nil? || band_max.nil?
      return :below if expected_max < band_min
      return :above if expected_min > band_max

      :within
    end

    def label(fit) = LABELS.fetch(fit).first
    def tone(fit) = LABELS.fetch(fit).last
  end
end
