module Gates
  # D60 / plan §a: closes the gate "Seleksi CV dan Tes Teknis" (S1 + S2) as one step.
  #
  # 1. An applicant whose CURRENT S1 decision is eliminate and whose S2 has no decision gets an
  #    append-only rule decision on S2, reason "gate_eliminated", with no score: the test of someone
  #    already out is never scored (plan §a.1). It is written HERE, when S1 is final (every S1
  #    participant decided, no review left), and not when S1 is first decided: an S1 elimination can
  #    still be reversed while the stage is open (a reviewer, or a threshold change that re-decides
  #    threshold decisions), and an S2 row written early would then shut out a candidate who is back
  #    in. A build decision.
  # 2. Both stages close through Stages::Close, which refuses while anyone is undecided or in review.
  # Everything is one transaction: a refusal at any step writes nothing.
  class Close
    REASON = "gate_eliminated".freeze

    def self.call(stage:, now: Time.current)
      members = stage.gate_members
      raise ArgumentError, "stage #{stage.code} has no gate; use Stages::Close" unless stage.gated?
      raise ArgumentError, "gate #{stage.gate} needs both S1 and S2" unless members.map(&:code) == %w[S1 S2]

      ActiveRecord::Base.transaction do
        members.each(&:lock!)
        not_open = members.reject { |member| member.status == "open" }
        raise ArgumentError, "gate #{stage.gate} closes only when both stages are open" if not_open.any?

        # F-06: the database accepts gate_eliminated only while this S2 stage is being closed.
        closing(members.last.id) { eliminate_followers(*members, now) }
        members.each { |member| Stages::Close.call(stage: member, within_gate: true) }
        Constraint.check_now!
      end
      # Plan §e: one gate-outcome email per applicant, AFTER the close has committed (a mail is not
      # something a rollback can take back). TechnicalTests::Tick sends any that this call missed.
      TechnicalTests::Notices.gate_outcomes(stage.job)
      stage.reload
    end

    def self.eliminate_followers(s1, s2, now)
      s1_by_application = s1.participations.to_h { |p| [p.job_application_id, p] }
      s2.participations.find_each do |p2|
        p1 = s1_by_application[p2.job_application_id]
        next unless p1&.current_decision&.outcome == "eliminate"
        next if p2.current_decision

        Decision.create!(participation: p2, outcome: "eliminate", basis: "rule", reason_code: REASON, decided_at: now)
      end
    end
    private_class_method :eliminate_followers

    # Names the S2 stage in the transaction-local setting glassbox.gate_closing (trigger
    # decisions_gate_eliminated reads it), and clears it again so an enclosing transaction cannot
    # write a gate row afterwards.
    def self.closing(s2_id)
      set = ->(value) { ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT set_config('glassbox.gate_closing', ?, true)", value])) }
      set.call(s2_id.to_s)
      yield
    ensure
      set&.call("")
    end
    private_class_method :closing
  end
end
