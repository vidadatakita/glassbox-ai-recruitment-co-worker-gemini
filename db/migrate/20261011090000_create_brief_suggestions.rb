# AI Builder Cup step 01: the AI's proposal for a job brief (activities, 90-day target, three-tier
# requirements) from the job title. Kept as it was proposed, so the brief page can show what the AI
# proposed beside what the person approved. Append-only: a new proposal is a new row.
class CreateBriefSuggestions < ActiveRecord::Migration[8.1]
  def up
    create_table :brief_suggestions do |t|
      t.references :job, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :model_id, null: false
      t.string :prompt_version, null: false
      t.jsonb :payload, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.datetime :created_at, null: false
    end

    execute <<~SQL
      CREATE TRIGGER brief_suggestions_append_only BEFORE UPDATE OR DELETE ON brief_suggestions
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER brief_suggestions_no_truncate BEFORE TRUNCATE ON brief_suggestions
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL
  end

  def down
    drop_table :brief_suggestions
  end
end
