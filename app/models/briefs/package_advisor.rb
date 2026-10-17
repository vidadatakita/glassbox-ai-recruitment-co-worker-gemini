# frozen_string_literal: true

module Briefs
  # Blueprint §7.1: the Golongan classifies the recruitment process and recommends a package.
  # The table names TWO packages for G1-2 ("2 Saring or 3 Seleksi") and for G6-8 ("4 or 5 Tuntas"),
  # so the recommendation is a SET; choosing outside it is an override that needs a written reason
  # (process card 3). Which member is pre-selected on the form is a manual choice (the lower one,
  # listed first), not a rule: the spec names no volume input that would choose between them.
  module PackageAdvisor
    NAMES = { 1 => "Post", 2 => "Screen", 3 => "Select", 4 => "Full Selection", 5 => "End-to-end" }.freeze
    RECOMMENDED = { 1 => [2, 3], 2 => [2, 3], 3 => [3], 4 => [3], 5 => [3], 6 => [3], 7 => [3], 8 => [3] }.freeze
    REASONS = {
      [1, 2] => "Grade 1-2 (operative staff): CV screening, a work test and a short interview are enough to choose.",
      [3] => "Grade 3 (team leader): an HR interview is needed besides the test, because the person leads a small team.",
      [4, 5] => "Grade 4-5 (supervisor): CV screening, a work test and two interviews.",
      [6, 7, 8] => "Grade 6-8 (manager and above): CV screening, a work test and two interviews."
    }.freeze

    module_function

    def recommended(golongan) = RECOMMENDED.fetch(golongan) { raise ArgumentError, "grade must be 1-8, got #{golongan.inspect}" }

    def default_choice(golongan) = recommended(golongan).first

    def recommended?(golongan, package) = recommended(golongan).include?(package)

    def reason(golongan) = REASONS.find { |group, _| group.include?(golongan) }&.last

    def label(package) = "#{package} #{NAMES.fetch(package)}"

    # Process card 3: a package outside the recommendation is stored with its reason.
    def override_problem(golongan, package, reason)
      return if package.nil? || recommended?(golongan, package) || reason.to_s.strip.present?

      "Package #{label(package)} differs from the recommendation for G#{golongan} " \
        "(#{recommended(golongan).map { |p| label(p) }.join(' or ')}). Write the reason for choosing this package."
    end
  end
end
