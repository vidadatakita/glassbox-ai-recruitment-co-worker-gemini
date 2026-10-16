# frozen_string_literal: true

# Screening standard item (FLOW §8.11, Appendix D structure): the discrimination test on the brief's
# requirements is stored on the vacancy, so the brief screen shows the verdicts and the brief cannot
# be completed while a flagged line waits for the HR owner's decision (Briefs::RequirementCheck).
# One jsonb document per vacancy: checked_at, prompt_version, the digest of the requirements it was
# run on (so an edited requirement makes the stored result stale), and the lines with each person's
# decision. Additive, no backfill: an existing vacancy simply has no stored test yet.
class AddRequirementCheckToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :requirement_check, :jsonb, null: false, default: {}
  end
end
