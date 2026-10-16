module Gates
  # The gate outcome for one applicant (D60): continues only when BOTH S1 and S2 current decisions
  # are pass. Either elimination ends it; anything else (no decision yet, a review) is still open.
  # Plain Ruby, no database: the caller passes the two current decisions (or nil).
  module Result
    LABELS = { passed: "Passed", not_passed: "Not passed", open: "Waiting" }.freeze
    TONES = { passed: "success", not_passed: "danger", open: "info" }.freeze

    module_function

    def of(s1_decision, s2_decision)
      outcomes = [s1_decision&.outcome, s2_decision&.outcome]
      return :not_passed if outcomes.include?("eliminate")
      return :passed if outcomes == %w[pass pass]

      :open
    end
  end
end
