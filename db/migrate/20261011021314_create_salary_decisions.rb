# AI Builder Cup step 08: the AI recommends a POSITION within the job's salary band (0 = bottom,
# 1 = top; it never sees a rupiah figure or the candidate's expected salary); the code turns it into
# rupiah; the owner agrees a figure. Both append-only: a new row replaces the shown one.
class CreateSalaryDecisions < ActiveRecord::Migration[8.1]
  def up
    create_table :salary_recommendations do |t|
      t.references :job_application, null: false, foreign_key: true
      t.bigint :requested_by_id, null: false
      t.string :status, null: false
      t.decimal :position, precision: 4, scale: 3
      t.bigint :amount
      t.text :summary
      t.jsonb :factors, null: false, default: []
      t.text :problem
      t.string :model_id
      t.string :prompt_version, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :salary_recommendations, :users, column: :requested_by_id
    add_check_constraint :salary_recommendations, "status IN ('ready', 'failed')", name: "salary_recommendations_status"
    add_check_constraint :salary_recommendations,
                         "(status = 'ready') = (position BETWEEN 0 AND 1 AND amount > 0 AND model_id IS NOT NULL)",
                         name: "salary_recommendations_ready_complete"

    create_table :salary_agreements do |t|
      t.references :job_application, null: false, foreign_key: true
      t.references :salary_recommendation, foreign_key: true
      t.bigint :agreed_amount, null: false
      t.boolean :outside_band, null: false
      t.text :note
      t.bigint :decided_by_id, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :salary_agreements, :users, column: :decided_by_id
    add_check_constraint :salary_agreements, "agreed_amount > 0", name: "salary_agreements_positive"
    add_check_constraint :salary_agreements, "NOT outside_band OR length(btrim(coalesce(note, ''))) > 0",
                         name: "salary_agreements_outside_band_has_note"

    execute <<~SQL
      CREATE FUNCTION enforce_salary_decider() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.decided_by_id) IS DISTINCT FROM 'owner' THEN
          RAISE EXCEPTION 'salary agreement refused: only the owner decides (AI Builder Cup step 08)'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    execute "CREATE TRIGGER salary_agreements_owner BEFORE INSERT ON salary_agreements FOR EACH ROW EXECUTE FUNCTION enforce_salary_decider();"
    %i[salary_recommendations salary_agreements].each do |table|
      execute "CREATE TRIGGER #{table}_append_only BEFORE DELETE OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
      execute "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
    end
  end

  def down
    drop_table :salary_agreements
    drop_table :salary_recommendations
    execute "DROP FUNCTION enforce_salary_decider()"
  end
end
