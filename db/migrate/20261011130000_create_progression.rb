# AI Builder Cup step 06 (D63 plan option C1 a): the AI recommends Lanjut or Tidak Lanjut with
# reasons; a named HR PIC chooses Lanjut / Rekomendasi AI / Tidak Lanjut, and that choice, not the
# AI and not the threshold, moves the candidate to the next stage.
#
#   stage_recommendations  one AI recommendation per request (a newer one supersedes by being newer);
#                          advisory only, never a score or a Decision.
#   progression_choices    one choice per stage participation (for the S1+S2 gate: on the S1 row),
#                          by the HR PIC (trigger), naming the recommendation it followed.
#   score_entries.note     the interviewer's note on an interview scorecard (S3).
# Both new tables are append-only, like every record of who decided what.
class CreateProgression < ActiveRecord::Migration[8.1]
  def up
    add_column :score_entries, :note, :text

    create_table :stage_recommendations do |t|
      t.references :participation, null: false, foreign_key: true
      t.bigint :requested_by_id, null: false
      t.string :status, null: false
      t.string :advice
      t.decimal :ai_score, precision: 4, scale: 1
      t.text :summary
      t.jsonb :reasons, null: false, default: {}
      t.text :problem
      t.string :model_id
      t.string :prompt_version, null: false
      t.string :input_sha256
      t.datetime :created_at, null: false
    end
    add_foreign_key :stage_recommendations, :users, column: :requested_by_id
    add_check_constraint :stage_recommendations, "status IN ('ready', 'failed', 'held')", name: "stage_recommendations_status"
    add_check_constraint :stage_recommendations,
                         "(status = 'ready') = (advice IN ('lanjut', 'tidak_lanjut') AND model_id IS NOT NULL)",
                         name: "stage_recommendations_ready_has_advice"
    add_check_constraint :stage_recommendations, "ai_score IS NULL OR ai_score BETWEEN 0 AND 100", name: "stage_recommendations_score_range"

    create_table :progression_choices do |t|
      t.references :participation, null: false, foreign_key: true, index: { unique: true }
      t.references :stage_recommendation, foreign_key: true
      t.string :choice, null: false
      t.string :direction, null: false
      t.text :note
      t.bigint :actor_id, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :progression_choices, :users, column: :actor_id
    add_check_constraint :progression_choices, "choice IN ('lanjut', 'ikut_ai', 'tidak_lanjut')", name: "progression_choices_choice"
    add_check_constraint :progression_choices, "direction IN ('lanjut', 'tidak_lanjut')", name: "progression_choices_direction"
    add_check_constraint :progression_choices, "choice = 'ikut_ai' OR choice = direction", name: "progression_choices_direction_matches"
    add_check_constraint :progression_choices, "choice <> 'ikut_ai' OR stage_recommendation_id IS NOT NULL",
                         name: "progression_choices_ai_names_recommendation"
    add_check_constraint :progression_choices, "direction = 'lanjut' OR length(btrim(coalesce(note, ''))) > 0",
                         name: "progression_choices_tidak_lanjut_has_note"

    # CREATE OR REPLACE, with the company check, on purpose: by timestamp this migration runs AFTER
    # 20261011030815, which already created this function with the user_in_job_company() check. A
    # plain CREATE stops a from-scratch db:migrate ("function already exists"), and replacing it
    # with a body that lacks the company check would let an HR PIC of another company choose
    # (tenant scoping). Databases that ran this migration before 20261011030815 are unaffected:
    # that migration's CREATE OR REPLACE already left this exact body.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_progression_chooser() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.actor_id) IS DISTINCT FROM 'hr_pic' THEN
          RAISE EXCEPTION 'progression choice refused: only the HR PIC chooses (AI Builder Cup step 06)'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NOT user_in_job_company(NEW.actor_id, (SELECT s.job_id FROM participations p JOIN stages s ON s.id = p.stage_id WHERE p.id = NEW.participation_id)) THEN
          RAISE EXCEPTION 'progression choice refused: the HR PIC belongs to another company' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    execute "CREATE TRIGGER progression_choices_hr_pic BEFORE INSERT ON progression_choices " \
            "FOR EACH ROW EXECUTE FUNCTION enforce_progression_chooser();"
    %i[stage_recommendations progression_choices].each do |table|
      execute "CREATE TRIGGER #{table}_append_only BEFORE DELETE OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
      execute "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
    end
  end

  def down
    drop_table :progression_choices
    drop_table :stage_recommendations
    execute "DROP FUNCTION enforce_progression_chooser()"
    remove_column :score_entries, :note
  end
end
