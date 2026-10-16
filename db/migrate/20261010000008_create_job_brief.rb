# Feature 03, the job form "Buat Lowongan" (blueprint §2.1, §2.3, §3.1 screen 2, §7.1; decisions
# D48 and D49). Additive only: new nullable columns on jobs, three child tables, and an
# append-only audit table. Every new jobs column is nullable or defaulted, because the scoring
# tests (ScoringFactory) and the two demo jobs create jobs with only a title and a Golongan; the
# brief rules (shares 100, weights 100, coverage) are checked by Briefs::BriefCheck when a brief
# is completed, not by the database, so a draft can be saved half-filled.
class CreateJobBrief < ActiveRecord::Migration[8.1]
  def up
    change_table :jobs, bulk: true do |t|
      t.integer :headcount
      # D49 (2): Tetap (PKWTT), Kontrak (PKWT), Harian Lepas, Magang.
      t.string :employment_type
      # Concept brief §2.2 "Sistem kerja": onsite / hybrid / remote. Optional.
      t.string :work_arrangement
      # Placement cities, one per entry. Multi-value (blueprint §3: separately grouped list).
      t.string :placements, array: true, null: false, default: []
      # Concept brief §2.2 "Bersedia ditempatkan di luar kota": optional, NULL = not stated.
      t.string :relocation
      t.text :success_90d
      # Concept brief §3: 1 Pasang, 2 Saring, 3 Seleksi, 4 Seleksi Lengkap, 5 Tuntas.
      t.integer :package
      # Process card 3: the client chose a package outside the §7.1 recommendation.
      t.text :package_override_reason
      # Weights and thresholds typed in step 4 while the brief is a draft, keyed by stage code
      # ({"S1" => {"weight" => 10, "threshold" => 60}}). Stage rows are written from it only when
      # the brief is completed (Briefs::Complete), so a half-typed plan never reaches a Stage.
      t.jsonb :stage_plan, null: false, default: {}
      t.string :brief_status, null: false, default: "draft"
      t.datetime :brief_completed_at
    end
    add_check_constraint :jobs, "employment_type IS NULL OR employment_type IN ('tetap_pkwtt','kontrak_pkwt','harian_lepas','magang')",
                         name: "jobs_employment_type"
    add_check_constraint :jobs, "work_arrangement IS NULL OR work_arrangement IN ('onsite','hybrid','remote')", name: "jobs_work_arrangement"
    add_check_constraint :jobs, "relocation IS NULL OR relocation IN ('wajib','diutamakan','tidak_perlu')", name: "jobs_relocation"
    add_check_constraint :jobs, "headcount IS NULL OR headcount > 0", name: "jobs_headcount_positive"
    add_check_constraint :jobs, "package IS NULL OR package BETWEEN 1 AND 5", name: "jobs_package_1_to_5"
    add_check_constraint :jobs, "brief_status IN ('draft','complete')", name: "jobs_brief_status"

    # Blueprint §2.1 Activity [P1]: 5-8 per job, shares summing to 100 (checked at completion).
    create_table :activities do |t|
      t.references :job, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :description, null: false
      t.text :output, null: false
      t.integer :share_percent, null: false
      t.timestamps
    end
    add_check_constraint :activities, "share_percent BETWEEN 0 AND 100", name: "activities_share_0_to_100"

    # Blueprint §2.1 Requirement [P3]: three tiers; a weight only on "sebaiknya" (should-have),
    # the sebaiknya weights summing to 100 (checked at completion).
    create_table :requirements do |t|
      t.references :job, null: false, foreign_key: true
      t.string :tier, null: false
      t.integer :position, null: false
      t.text :text, null: false
      t.text :cv_evidence, null: false
      t.integer :weight
      t.timestamps
    end
    add_check_constraint :requirements, "tier IN ('wajib','sebaiknya','nilai_tambah')", name: "requirements_tier"
    add_check_constraint :requirements, "weight IS NULL OR (tier = 'sebaiknya' AND weight BETWEEN 0 AND 100)",
                         name: "requirements_weight_only_sebaiknya"

    # Blueprint §2.1 Requirement "knockout question (optional) [P8]": a knockout question is
    # derived from a must-have requirement. Nullable: the demo jobs' questions have no requirement.
    add_reference :knockout_questions, :requirement, foreign_key: true, index: { unique: true }

    # Blueprint §2.1 Competency [P4, P17]: one layer, exactly one owning stage, anchors 1/3/5,
    # interview questions for the interview stages (S3, S5).
    create_table :competencies do |t|
      t.references :job, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :name, null: false
      t.string :layer, null: false
      t.string :stage_code, null: false
      t.text :anchor_1
      t.text :anchor_3
      t.text :anchor_5
      t.text :questions
      t.timestamps
    end
    add_check_constraint :competencies, "layer IN ('L1','L2','L3','L4','L5','I')", name: "competencies_layer"
    add_check_constraint :competencies, "stage_code IN ('S1','S2','S3','S4','S5')", name: "competencies_stage_code"

    # D49 (5): "every change recorded". One row per saved step that changed something: who, in
    # which role, which step, and the before/after of the fields that changed. Append-only, like
    # setting_changes: the trigger refuses UPDATE, DELETE and TRUNCATE.
    create_table :job_brief_changes do |t|
      t.references :job, null: false, foreign_key: true
      t.bigint :actor_id, null: false
      t.string :actor_role, null: false
      t.string :step, null: false
      t.jsonb :changes_made, null: false, default: {}
      t.datetime :created_at, null: false
    end
    execute <<~SQL
      CREATE TRIGGER job_brief_changes_append_only BEFORE UPDATE OR DELETE ON job_brief_changes
      FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER job_brief_changes_no_truncate BEFORE TRUNCATE ON job_brief_changes
      FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
