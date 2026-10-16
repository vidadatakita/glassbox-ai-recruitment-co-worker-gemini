module Stages
  # Closes a stage (blueprint §3.4). Refused while any participation has no current decision
  # or is still in review, so nobody is left behind silently when the next stage opens.
  class Close
    class Undecided < StandardError; end
    # D60: S1 and S2 of a gate close together, through Gates::Close only (which passes
    # within_gate: true). The database refuses a lone close at commit as well.
    class GateRefused < StandardError; end

    def self.call(stage:, within_gate: false)
      if stage.gated? && !within_gate
        raise GateRefused, "stage #{stage.code} belongs to gate #{stage.gate}: close it with Gates::Close, together with its partner"
      end
      raise ArgumentError, "only an open stage can be closed (status: #{stage.status})" unless stage.status == "open"

      undecided = stage.participations.reject do |participation|
        decision = participation.current_decision
        decision && decision.outcome != "review"
      end
      if undecided.any?
        ids = undecided.map(&:job_application_id).join(", ")
        raise Undecided, "stage #{stage.code} has undecided applications: #{ids}"
      end

      # D37: closing a stage nobody entered is allowed, and said in the log, so an empty
      # stage closing is visible to whoever reads the job's history.
      if stage.participations.empty?
        Rails.logger.info("event=stage_closed_empty stage_id=#{stage.id} job_id=#{stage.job_id} code=#{stage.code}")
      end
      stage.allow_close { stage.update!(status: "closed") }
      stage
    end
  end
end
