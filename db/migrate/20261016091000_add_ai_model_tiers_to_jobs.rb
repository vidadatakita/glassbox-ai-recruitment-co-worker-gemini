# frozen_string_literal: true

# FLOW v2.1 §9 rule 2 (model tiers, team decision 16 Oct 2026): the tier → model mapping in force when the
# applicant portal opens is stored on the vacancy, so a later change of AI_MODEL_<TIER> never alters
# the results of an open vacancy, and the vacancy page can print "Models locked at open: HIGH …".
# One jsonb document: { "high" => { "model", "thinking" }, "medium" => …, "low" => … }. Empty for a
# vacancy opened before this migration: Screening::Config then resolves from the environment, as before.
class AddAiModelTiersToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :ai_model_tiers, :jsonb, null: false, default: {}
  end
end
