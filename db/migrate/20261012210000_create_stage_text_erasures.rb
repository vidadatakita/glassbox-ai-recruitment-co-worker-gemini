# Erasure of the AI Builder Cup D63 texts (GlassBox Team, 2026-10-12 20:28, "3 build"). UU PDP / D16 / blueprint
# §4.2: when consent is withdrawn or the retention period ends, every free text about the candidate is
# erased; scores, decisions, who and when stay for anonymous statistics. Before this migration the Cup
# tables (stage_recommendations, salary_recommendations, progression_choices, salary_agreements, and
# interviewer notes on score_entries) were plain append-only, so these texts survived withdrawal.
#
# Same shape as ai_release_erasures and screening_result_erasures: an append-only erasure row is
# written FIRST (who, why, when); only then does a trigger allow exactly one change on the target row:
# the listed text columns set to NULL (jsonb columns to their empty default; a note that a CHECK
# requires, to the fixed marker "[dihapus]"). Every other UPDATE and
# every DELETE stays refused, with the existing "is append-only" message.
class CreateStageTextErasures < ActiveRecord::Migration[8.1]
  # table => { column => value it is erased to }
  TEXTS = {
    "stage_recommendations" => { "summary" => "NULL", "reasons" => "'{}'::jsonb", "problem" => "NULL" },
    "salary_recommendations" => { "summary" => "NULL", "factors" => "'[]'::jsonb", "problem" => "NULL" },
    "progression_choices" => { "note" => "'[dihapus]'" }, # a Tidak Lanjut note is required (CHECK)
    "salary_agreements" => { "note" => "'[dihapus]'" }, # a note may be required (outside the band)
    "score_entries" => { "note" => "NULL" }
  }.freeze

  def up
    create_table :stage_text_erasures do |t|
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.references :job_application, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users } # NULL = the system or the candidate
      t.string :reason, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_index :stage_text_erasures, %i[record_type record_id], unique: true
    add_check_constraint :stage_text_erasures, "record_type IN (#{TEXTS.keys.map { |k| "'#{k}'" }.join(', ')})",
                         name: "stage_text_erasures_record_type"
    add_check_constraint :stage_text_erasures, "reason IN ('retention_expired', 'consent_withdrawn', 'no_consent')",
                         name: "stage_text_erasures_reason"
    execute "CREATE TRIGGER stage_text_erasures_append_only BEFORE DELETE OR UPDATE ON stage_text_erasures " \
            "FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
    execute "CREATE TRIGGER stage_text_erasures_no_truncate BEFORE TRUNCATE ON stage_text_erasures " \
            "FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"

    # TG_ARGV = the erasable columns, then for each its erased value as JSON text (null, {} or []).
    execute <<~SQL
      CREATE OR REPLACE FUNCTION stage_text_erase_only() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        i int := 0;
        col text;
        erased jsonb;
        old_rest jsonb := to_jsonb(OLD);
        new_rest jsonb := to_jsonb(NEW);
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP USING ERRCODE = 'restrict_violation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM stage_text_erasures e WHERE e.record_type = TG_TABLE_NAME AND e.record_id = OLD.id) THEN
          RAISE EXCEPTION '% is append-only: % refused (no erasure row)', TG_TABLE_NAME, TG_OP USING ERRCODE = 'restrict_violation';
        END IF;
        WHILE i < TG_NARGS LOOP
          col := TG_ARGV[i];
          erased := TG_ARGV[i + 1]::jsonb;
          IF (new_rest -> col) IS DISTINCT FROM erased AND NOT ((new_rest -> col) = 'null'::jsonb AND erased = 'null'::jsonb) THEN
            RAISE EXCEPTION '% is append-only: % refused (only erasing %.% is allowed)', TG_TABLE_NAME, TG_OP, TG_TABLE_NAME, col
              USING ERRCODE = 'restrict_violation';
          END IF;
          old_rest := old_rest - col;
          new_rest := new_rest - col;
          i := i + 2;
        END LOOP;
        IF old_rest IS DISTINCT FROM new_rest THEN
          RAISE EXCEPTION '% is append-only: % refused (only text columns may be erased)', TG_TABLE_NAME, TG_OP
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL

    TEXTS.each do |table, columns|
      args = columns.flat_map { |col, value| [col, json_of(value)] }.map { |a| "'#{a}'" }.join(", ")
      execute "DROP TRIGGER IF EXISTS #{table}_append_only ON #{table};"
      execute "CREATE TRIGGER #{table}_append_only BEFORE DELETE OR UPDATE ON #{table} " \
              "FOR EACH ROW EXECUTE FUNCTION stage_text_erase_only(#{args});"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def json_of(value) = { "NULL" => "null", "'{}'::jsonb" => "{}", "'[]'::jsonb" => "[]", "'[dihapus]'" => '"[dihapus]"' }.fetch(value)
end
