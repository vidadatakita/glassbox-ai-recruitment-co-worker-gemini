# AI Builder Cup step 05: "Gemini scores the test answer against its rubric; a person decides". One
# row per AI scoring a reviewer asked for: who sent it, the SHA-256 of the exact text that was sent
# (the reviewer saw that text before sending), the model, and the proposed rating and reason per
# criterion. A proposal only; the score is still the reviewer's (TechnicalTests::ScoreAnswer).
# Append-only, like every other record of who decided what.
class CreateTestAiSuggestions < ActiveRecord::Migration[8.1]
  def up
    create_table :test_ai_suggestions do |t|
      t.references :test_attempt, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :sent_sha256, null: false
      t.string :model_id, null: false
      t.string :prompt_version, null: false
      t.jsonb :payload, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.datetime :created_at, null: false
    end

    execute <<~SQL
      CREATE TRIGGER test_ai_suggestions_append_only BEFORE UPDATE OR DELETE ON test_ai_suggestions
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER test_ai_suggestions_no_truncate BEFORE TRUNCATE ON test_ai_suggestions
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL
  end

  def down
    drop_table :test_ai_suggestions
  end
end
