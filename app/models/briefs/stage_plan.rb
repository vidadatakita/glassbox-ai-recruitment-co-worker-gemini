# frozen_string_literal: true

module Briefs
  # Which stages a package runs, their score source, and the default weights.
  #
  # Stages per package come from the package ladder (concept brief §3): S5 is client-run and
  # scored in the portal in packages 1-3; the reference check runs in packages 4-5 (blueprint §3.4).
  # NOTE the §7.1 default plan for G1-2 ("S1, S2 work sample, S5") matches neither package 2 (no
  # S2) nor package 3 (adds S3); the ladder wins here, and the gap is an open spec conflict the team
  # has not ruled on.
  module StagePlan
    CODES = {
      1 => %w[S5], 2 => %w[S1 S5], 3 => %w[S1 S2 S3 S5],
      4 => %w[S1 S2 S3 S4 S5 RC], 5 => %w[S1 S2 S3 S4 S5 RC]
    }.freeze
    SOURCES = { "S1" => "ai", "S2" => "manual_or_import", "S3" => "scorecard", "S4" => "manual_or_import",
                "S5" => "scorecard", "RC" => "check" }.freeze
    LABELS = { "S1" => "CV screening", "S2" => "Technical test", "S3" => "Interview 1 (HR)", "S4" => "Psychological test",
               "S5" => "Interview 2 (hiring manager)", "RC" => "Reference check" }.freeze
    # Concept brief §4.1 default weights, "to be tuned per role", re-normalised over the stages a
    # package runs. RC has no score (rule 12), so it carries weight 0 and is outside the 100.
    DEFAULT_WEIGHTS = { "S1" => 10, "S2" => 20, "S3" => 20, "S4" => 20, "S5" => 30 }.freeze

    module_function

    def codes(package) = CODES.fetch(package) { raise ArgumentError, "package must be 1-5, got #{package.inspect}" }

    def scored_codes(package) = codes(package) - ["RC"]

    def source(code) = SOURCES.fetch(code)

    # Rule 13 / D12: the psychological test of a staff-level role (G1-3, the "Staff" groupings of
    # §7.1) puts a below-threshold score into review instead of eliminating.
    def review_below_threshold?(code, golongan) = code == "S4" && golongan <= 3

    # The concept-brief defaults re-normalised to whole percent summing to exactly 100. Integer
    # weights cannot always hit the exact share (package 3: 12.5 / 25 / 25 / 37.5), so this uses
    # the largest-remainder method, ties going to the earlier stage. A PREFILL the user edits,
    # not a rule.
    def default_weights(package)
      codes = scored_codes(package)
      total = codes.sum { |c| DEFAULT_WEIGHTS.fetch(c) }
      exact = codes.to_h { |c| [c, Rational(DEFAULT_WEIGHTS.fetch(c) * 100, total)] }
      floors = exact.transform_values(&:floor)
      short = 100 - floors.values.sum
      codes.sort_by.with_index { |c, i| [-(exact[c] - floors[c]), i] }.first(short).each { |c| floors[c] += 1 }
      floors
    end
  end
end
