module Stages
  # Opens a draft stage. Setting opened_at is what locks weight and threshold (rule 3).
  #
  # Facts that arrived while the stage was a draft are decided here, by rule, because a decision
  # cannot be written on a draft stage (D37): a knockout "tidak" (rule 16; the AI never sees the
  # application) and a consent withdrawal (reason "withdrew", test engine F3). Same transaction,
  # so a stage never opens with such an applicant left undecided.
  #
  # D60: a stage that belongs to a gate (S1 + S2 on packages 3+) never opens alone; the call is
  # handed to Gates::Open, which opens every member in one transaction. gate_member: true is that
  # service opening one member; nobody else passes it.
  class Open
    def self.call(stage:, now: Time.current, gate_member: false)
      return Gates::Open.call(stage:, now:) if stage.gated? && !gate_member
      raise ArgumentError, "only a draft stage can be opened (status: #{stage.status})" unless stage.status == "draft"

      ActiveRecord::Base.transaction do
        stage.update!(status: "open", opened_at: now)
        decide_rule_facts(stage, now)
      end
      stage
    end

    def self.decide_rule_facts(stage, now)
      stage.participations.includes(:job_application).find_each do |participation|
        application = participation.job_application
        withdrawn = application.consent_withdrawn_at.present?
        next unless application.knocked_out? || withdrawn
        next if participation.current_decision

        participation.update!(attendance: "withdrew") if withdrawn
        result = Scoring::Decider.decide(score: nil, threshold: stage.threshold, attendance: participation.attendance.to_sym,
                                         knockout_failed: application.knocked_out? && !withdrawn)
        Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s,
                         reason_code: result.reason_code, decided_at: now)
      end
    end
    private_class_method :decide_rule_facts
  end
end
