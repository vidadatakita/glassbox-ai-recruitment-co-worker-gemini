module ScreeningReport
  # "Hasil Seleksi CV" (SPEC §1, D60): the screening gate result per applicant. On a gated job
  # (packages 3-5) it is Gates::Result over the S1 and S2 current decisions, and an elimination says
  # WHICH part failed, as in SPEC §3 example B "Not passed (test)". On a package-2 job (S1 only) it
  # is the S1 decision alone. An S1 elimination wins the wording when both failed (the test of an
  # S1-eliminated candidate is never scored: gate_eliminated, feature 07).
  module GateCell
    LABELS = {
      passed: ["Passed", "success"], open: ["Waiting", "info"],
      failed_cv: ["Not passed (CV)", "danger"], failed_test: ["Not passed (test)", "danger"]
    }.freeze
    # Sort order (h9 "gate result first"): who continues, then who still waits, then who is out.
    ORDER = { passed: 0, open: 1, failed_cv: 2, failed_test: 2 }.freeze

    module_function

    def of(s1_decision, s2_decision, gated:)
      return :failed_cv if s1_decision&.outcome == "eliminate"

      if gated
        result = Gates::Result.of(s1_decision, s2_decision)
        return :failed_test if result == :not_passed
        return result == :passed ? :passed : :open
      end
      s1_decision&.outcome == "pass" ? :passed : :open
    end

    def word(key) = LABELS.fetch(key).first
    def tone(key) = LABELS.fetch(key).last
  end
end
