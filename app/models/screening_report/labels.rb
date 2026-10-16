module ScreeningReport
  # The screening label ("Analisa" in the SPEC, §1, D61). The AI proposes one of five; a reviewer confirms one of six
  # (Over-qualified only by the reviewer, D62 h3). Colour always travels with the word, never alone
  # (SPEC §1): green = Recommended; amber = Consider, Over-qualified, Not a priority;
  # red = Not relevant. "Consider with reservations" has no colour in the SPEC: amber is the builder's
  # default (it is a "consider", not a rejection). The label is advisory; the 30% gate decides (h4).
  module Labels
    ALL = {
      "direkomendasikan" => ["Recommended", "success"],
      "pertimbangkan" => ["Consider", "warning"],
      "pertimbangkan_terbatas" => ["Consider with reservations", "warning"],
      "over_qualified" => ["Over-qualified", "warning"],
      "tidak_prioritas" => ["Not a priority", "warning"],
      "tidak_relevan" => ["Not relevant", "danger"]
    }.freeze
    # Report order (best first), used to show the choices in this order on the confirmation form.
    ORDER = ALL.keys.freeze
    OVER_QUALIFIED_GAP = 2

    module_function

    def word(key) = ALL.fetch(key).first
    def tone(key) = ALL.fetch(key).last

    # D62 h3: Over-qualified only when the last role is at least two Golongan above the job's.
    def over_qualified_allowed?(last_role_golongan:, job_golongan:)
      return false if last_role_golongan.nil? || job_golongan.nil?

      last_role_golongan - job_golongan >= OVER_QUALIFIED_GAP
    end
  end
end
