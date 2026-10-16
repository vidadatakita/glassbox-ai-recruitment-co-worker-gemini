class CreateScoringCore < ActiveRecord::Migration[8.1]
  def change
    # Minimal job: Plan 3 adds the brief, the role family and the price.
    create_table :jobs do |t|
      t.string :title, null: false
      t.integer :golongan, null: false
      t.string :status, null: false, default: "draft"
      t.timestamps
    end
    add_check_constraint :jobs, "golongan BETWEEN 1 AND 8", name: "jobs_golongan_1_to_8"

    create_table :stages do |t|
      t.references :job, null: false, foreign_key: true
      t.string :code, null: false
      t.string :score_source, null: false
      t.integer :weight, null: false
      t.decimal :threshold, precision: 4, scale: 1, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :opened_at
      # Rule 13 / D12: true for the psychological test of a staff-level (Golongan 1-3) role.
      t.boolean :review_below_threshold, null: false, default: false
      t.timestamps
    end
    add_index :stages, %i[job_id code], unique: true
    add_check_constraint :stages, "code IN ('S1','S2','S3','S4','S5','RC')", name: "stages_code"
    add_check_constraint :stages, "score_source IN ('ai','scorecard','manual_or_import','check')", name: "stages_score_source"
    add_check_constraint :stages, "status IN ('draft','open','closed')", name: "stages_status"
    add_check_constraint :stages, "weight BETWEEN 0 AND 100", name: "stages_weight_range"
    add_check_constraint :stages, "threshold BETWEEN 0 AND 100", name: "stages_threshold_range"

    # Minimal application: Plan 4 adds the candidate, consent, channel and CV.
    create_table :job_applications do |t|
      t.references :job, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    create_table :participations do |t|
      t.references :job_application, null: false, foreign_key: true
      t.references :stage, null: false, foreign_key: true
      t.string :attendance, null: false, default: "pending"
      t.datetime :scheduled_at
      t.timestamps
    end
    add_index :participations, %i[job_application_id stage_id], unique: true
    add_check_constraint :participations, "attendance IN ('pending','attended','no_show','withdrew')", name: "participations_attendance"

    create_table :score_entries do |t|
      t.references :participation, null: false, foreign_key: true
      t.decimal :value, precision: 4, scale: 1, null: false
      t.jsonb :ratings, null: false, default: {}
      t.bigint :entered_by_id, null: false   # FK to users added in Plan 2
      t.datetime :event_at                    # interview or test time; lag = entered_at - event_at
      t.datetime :entered_at, null: false
      t.bigint :supersedes_id
      t.text :correction_reason
    end
    add_foreign_key :score_entries, :score_entries, column: :supersedes_id
    # One row can be superseded once: two corrections racing on the same entry cannot both win.
    add_index :score_entries, :supersedes_id, unique: true
    add_check_constraint :score_entries, "value BETWEEN 0 AND 100", name: "score_entries_value_range"
    add_check_constraint :score_entries, "supersedes_id IS NULL OR correction_reason IS NOT NULL", name: "score_entries_correction_has_reason"

    create_table :decisions do |t|
      t.references :participation, null: false, foreign_key: true
      t.string :outcome, null: false
      t.string :basis, null: false
      t.string :reason_code, null: false
      t.text :note
      t.bigint :decided_by_id                 # null for decisions made by rule or threshold automatically
      t.datetime :decided_at, null: false
      t.bigint :supersedes_id
    end
    add_foreign_key :decisions, :decisions, column: :supersedes_id
    add_index :decisions, :supersedes_id, unique: true
    add_check_constraint :decisions, "outcome IN ('pass','eliminate','review')", name: "decisions_outcome"
    add_check_constraint :decisions, "basis IN ('threshold','manual','rule')", name: "decisions_basis"
    add_check_constraint :decisions, "basis <> 'manual' OR (note IS NOT NULL AND decided_by_id IS NOT NULL)", name: "decisions_manual_has_reason_and_actor"

    create_table :stage_changes do |t|
      t.references :stage, null: false, foreign_key: true
      t.string :field, null: false
      t.decimal :old_value, precision: 4, scale: 1, null: false
      t.decimal :new_value, precision: 4, scale: 1, null: false
      t.text :reason, null: false
      t.bigint :changed_by_id, null: false
      t.datetime :changed_at, null: false
    end
    add_check_constraint :stage_changes, "field IN ('weight','threshold')", name: "stage_changes_field"
  end
end
