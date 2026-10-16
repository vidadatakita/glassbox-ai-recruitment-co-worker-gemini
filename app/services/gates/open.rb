module Gates
  # D60: opens every stage of a gate ("Seleksi CV dan Tes Teknis" = S1 + S2) in one transaction, so
  # an applicant's CV screening and technical test start together. Each member goes through
  # Stages::Open (opened_at locks weight and threshold, rule 3; facts that arrived while the stage
  # was a draft are decided by rule there).
  class Open
    def self.call(stage:, now: Time.current)
      members = stage.gate_members
      undrafted = members.reject { |member| member.status == "draft" }
      if undrafted.any?
        raise ArgumentError, "gate #{stage.gate} can open only when all its stages are drafts " \
                             "(#{undrafted.map { |m| "#{m.code} #{m.status}" }.join(', ')})"
      end
      raise ArgumentError, "gate #{stage.gate} needs both S1 and S2" unless members.map(&:code) == %w[S1 S2]

      ActiveRecord::Base.transaction do
        members.each { |member| Stages::Open.call(stage: member, now:, gate_member: true) }
        Constraint.check_now!
      end
      stage.reload
    end
  end
end
