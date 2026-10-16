module TechnicalTests
  # The candidate-facing outcome of the gate "Seleksi CV dan Tes Teknis" for one application
  # (plan §e; D38 Q6a: shown only once BOTH stages are closed; D28/BP §3.6 B2: a reason CATEGORY,
  # never a score). Used by the status page and by the gate-outcome email, so the two say the same.
  #
  # Reason chosen from the decision that ended the gate: S1's own reason when S1 eliminated (never
  # "gate_eliminated", which is bookkeeping on S2); for S2, a technical-test no-show has its own
  # category, because the generic no-show line speaks of a schedule the candidate did not attend.
  class GateOutcome
    TEST_NO_SHOW = "The technical test was not taken within the time limit.".freeze

    attr_reader :s1, :s2

    def self.for(application)
      s1 = application.participations.joins(:stage).find_by(stages: { code: "S1" })
      s2 = TechnicalTests.participation_for(application)
      return nil if s1.nil? || s2.nil? || !s1.stage.gated?

      new(s1, s2)
    end

    def initialize(s1, s2)
      @s1 = s1
      @s2 = s2
    end

    def closed? = s1.stage.status == "closed" && s2.stage.status == "closed"
    def result = Gates::Result.of(s1.current_decision, s2.current_decision)
    def passed? = result == :passed
    def not_passed? = result == :not_passed
    def decided_at = [s1.current_decision&.decided_at, s2.current_decision&.decided_at].compact.max

    # The participation whose decision ended the gate (S1 first), so an S1 elimination keeps its
    # objection path (E21 is offered on S1 results only).
    def eliminating_participation
      return s1 if s1.current_decision&.outcome == "eliminate"

      s2 if s2.current_decision&.outcome == "eliminate"
    end

    def reason
      participation = eliminating_participation
      return nil if participation.nil?

      code = participation.current_decision.reason_code
      return TEST_NO_SHOW if participation == s2 && code == "no_show"

      CandidateStatus::REASON_CATEGORIES.fetch(code, CandidateStatus::DEFAULT_REASON)
    end
  end
end
