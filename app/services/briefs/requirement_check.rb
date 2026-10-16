# frozen_string_literal: true

module Briefs
  # The discrimination test (Appendix D structure) as the brief screen uses it: run it, store the
  # verdicts on the vacancy, let the HR owner decide each flagged line, and tell Briefs::Complete
  # whether a line is still open. Briefs::DiscriminationCheck produces the lines and decides nothing;
  # this module owns the record of what a person did with them.
  #
  # Stored on jobs.requirement_check:
  #   { "checked_at", "prompt_version", "digest", "lines" => [ line + "decision", "note", "decided_by", "decided_at" ] }
  # The digest is over the requirements the test saw. Editing a requirement afterwards makes the
  # stored result stale, so the next completion attempt runs the test again (no verdict is ever
  # reused for text the model never saw).
  #
  # Decisions on a flagged line ("replace" or "delete" verdict):
  #   keep     the person overrides the verdict; a reason is required (a person decides, with a reason)
  #   replace  the requirement's text becomes the neutral wording the test proposed
  #   delete   the requirement is removed from the brief
  # A "keep" verdict needs no decision. Every run and decision is recorded as a JobBriefChange (step 3).
  module RequirementCheck
    class Refused < StandardError; end

    DECISIONS = %w[keep replace delete].freeze

    module_function

    def stored(job) = job.requirement_check.presence || {}
    def lines(job) = Array(stored(job)["lines"])
    def ran?(job) = lines(job).any? || stored(job)["checked_at"].present?
    def stale?(job) = !ran?(job) || stored(job)["digest"] != digest(job)
    def open_lines(job) = lines(job).select { |l| l["verdict"] != "keep" && l["decision"].blank? }
    def open?(job) = !stale?(job) ? open_lines(job).any? : false

    # Runs the test and stores the result; earlier decisions are dropped because the lines are new.
    # record: a person's run is a brief change; the automatic run inside Briefs::Complete is not
    # (the completion row already records who completed, and the history stays one row per act).
    def run!(job:, actor:, now: Time.current, record: true)
      lines = DiscriminationCheck.call(job)
      job.update!(requirement_check: { "checked_at" => now.iso8601, "prompt_version" => DiscriminationCheck::PROMPT_VERSION,
                                       "digest" => digest(job), "lines" => lines })
      record!(job, actor, now, "requirement_check" => ["run", "#{lines.count { |l| l['verdict'] != 'keep' }} flagged of #{lines.size}"]) if record
      lines
    end

    # Briefs::Complete: a stale result is refreshed before the brief is judged, so a clean brief
    # completes as before and a flagged one stops with the lines on screen.
    def ensure_current!(job:, actor:, now: Time.current)
      run!(job:, actor:, now:, record: false) if job.requirements.exists? && stale?(job)
    end

    def decide!(job:, actor:, line_id:, decision:, note: nil, now: Time.current)
      raise Refused, "The requirements changed since the test ran. Run the test again first." if stale?(job)
      raise Refused, "Unknown decision." unless DECISIONS.include?(decision.to_s)

      doc = stored(job).deep_dup
      line = doc["lines"].find { |l| l["id"] == line_id.to_s }
      raise Refused, "This line is not in the stored test." if line.nil?
      raise Refused, "This line was already decided." if line["decision"].present?
      raise Refused, "This line is not flagged; nothing to decide." if line["verdict"] == "keep"
      raise Refused, "A reason is required to keep a flagged requirement." if decision.to_s == "keep" && note.to_s.strip.empty?
      raise Refused, "The test proposed no neutral wording for this line; reword it in step 3 or delete it." if decision.to_s == "replace" && line["replacement"].to_s.strip.empty?
      raise Refused, "A selection stage has opened; the requirements are locked." if job.brief_locked?

      requirement = job.requirements.find(line_id.to_s.delete_prefix("R"))
      ActiveRecord::Base.transaction do
        case decision.to_s
        when "replace" then requirement.update!(text: line["replacement"])
        when "delete"
          raise Refused, "Applications are already in; a requirement cannot be deleted now." if job.job_applications.exists?
          requirement.destroy!
        end
        line.merge!("decision" => decision.to_s, "note" => note.to_s.strip, "decided_by" => actor.id, "decided_by_name" => actor.name, "decided_at" => now.iso8601)
        job.reload
        doc["digest"] = digest(job) # the decision changed the text or the set: the stored result is current again
        job.update!(requirement_check: doc)
        record!(job, actor, now, "requirement_check" => [line_id.to_s, decision.to_s])
      end
      line
    end

    def digest(job)
      rows = job.requirements.reorder(:id).pluck(:id, :text, :cv_evidence)
      Digest::SHA256.hexdigest(JSON.generate(rows))
    end

    def record!(job, actor, now, changes)
      JobBriefChange.create!(job:, actor:, actor_role: actor.role, step: "3", changes_made: changes, created_at: now)
    end
  end
end
