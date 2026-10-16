# Feature 08, the screening report "Laporan Analisis Kandidat" (D61, D62). Additive only: new
# nullable columns and new tables; no existing row or constraint changes.
#
# 1. screening_results gains the S1 report fields (prompt s1-2026-10-10.3, plan Part 2 §i). They
#    are nullable because every result written before this prompt version has none, and because a
#    reply without the report block must still store its score (the report never gates S1).
#    label_proposal holds five of the six labels: "over_qualified" is never an AI proposal. D62 h3
#    defines it only as "last role >= 2 Golongan above the job", and the Golongan of the last role
#    is set by the reviewer on confirmation, never estimated by the model (years or age must never
#    stand in for it).
# 2. job_applications.expected_salary_min/max: the optional "Gaji yang diharapkan" on Lamar (D62
#    h5). Integer rupiah per month, both ends or neither. Never sent to the AI, never scored.
# 3. screening_label_confirmations: the reviewer confirms the Analisa label (E21: a person
#    decides). Append-only; the newest row per participation counts. Over-qualified needs a note
#    and a last-role Golongan at least two above the job's (snapshot checked against jobs.golongan
#    by the trigger, so the snapshot cannot be forged lower).
# 4. screening_narrative_approvals: the consultant approves the four AI narrative boxes (D62 h2);
#    until a row exists for the CURRENT result the screen says "Draf AI".
# 5. user_recommendations: "Rekomendasi User", entered by the HR PIC naming the hiring manager
#    (D62 h6, T1). Information only: it never moves a candidate. Append-only, newest wins.
class CreateScreeningReport < ActiveRecord::Migration[8.1]
  LABELS = %w[direkomendasikan pertimbangkan pertimbangkan_terbatas over_qualified tidak_prioritas tidak_relevan].freeze
  AI_LABELS = (LABELS - ["over_qualified"]).freeze

  def up
    add_report_columns
    add_expected_salary
    create_label_confirmations
    create_narrative_approvals
    create_user_recommendations
  end

  def down
    %w[user_recommendations screening_narrative_approvals screening_label_confirmations].each { |t| drop_table t }
    execute "DROP FUNCTION IF EXISTS enforce_label_confirmation(); DROP FUNCTION IF EXISTS enforce_narrative_approver(); DROP FUNCTION IF EXISTS enforce_user_recommendation_actor();"
    remove_check_constraint :job_applications, name: "job_applications_expected_salary"
    remove_column :job_applications, :expected_salary_min
    remove_column :job_applications, :expected_salary_max
    remove_check_constraint :screening_results, name: "screening_results_label_proposal"
    %i[last_position education recent_experience narratives label_proposal label_reason].each { |c| remove_column :screening_results, c }
  end

  private

  def add_report_columns
    # Each of the three facts: { "text", "quote", "verified" } (employer inside "text" for the
    # last position). narratives: { "strengths" | "blind_spots" | "tolerance_risks" |
    # "credibility_value" => [{ "claim", "quote", "verified" }] }.
    add_column :screening_results, :last_position, :jsonb
    add_column :screening_results, :education, :jsonb
    add_column :screening_results, :recent_experience, :jsonb
    add_column :screening_results, :narratives, :jsonb
    add_column :screening_results, :label_proposal, :string
    add_column :screening_results, :label_reason, :text
    add_check_constraint :screening_results, "label_proposal IS NULL OR label_proposal IN (#{quoted(AI_LABELS)})",
                         name: "screening_results_label_proposal"
  end

  def add_expected_salary
    add_column :job_applications, :expected_salary_min, :bigint
    add_column :job_applications, :expected_salary_max, :bigint
    # The explicit IS NOT NULLs are load-bearing: a CHECK passes when it evaluates to NULL, so
    # without them a half range (min set, max NULL) was accepted (seen red in
    # test/integration/lamar_expected_salary_test.rb, docs/red-runs.md feature 08 R1).
    add_check_constraint :job_applications,
                         "(expected_salary_min IS NULL AND expected_salary_max IS NULL) OR " \
                         "(expected_salary_min IS NOT NULL AND expected_salary_max IS NOT NULL AND " \
                         "expected_salary_min > 0 AND expected_salary_max >= expected_salary_min)",
                         name: "job_applications_expected_salary"
  end

  def create_label_confirmations
    create_table :screening_label_confirmations do |t|
      t.references :participation, null: false, foreign_key: true
      # No foreign key to screening_results, on purpose: Postgres refuses TRUNCATE of a referenced
      # table with a foreign-key error BEFORE its append-only trigger fires, which would replace
      # the "is append-only: TRUNCATE refused" guard with a different refusal (feature-06 engine
      # test calibration_review_and_records_test.rb:225). The trigger below checks the result
      # exists and belongs to the same participation; results are never deleted (append-only).
      t.references :screening_result, null: false, foreign_key: false
      t.bigint :reviewer_id, null: false
      t.string :label, null: false
      t.integer :last_role_golongan
      t.integer :job_golongan, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_foreign_key :screening_label_confirmations, :users, column: :reviewer_id
    add_check_constraint :screening_label_confirmations, "label IN (#{quoted(LABELS)})", name: "label_confirmations_label"
    add_check_constraint :screening_label_confirmations, "last_role_golongan IS NULL OR last_role_golongan BETWEEN 1 AND 8",
                         name: "label_confirmations_golongan_range"
    add_check_constraint :screening_label_confirmations,
                         "label <> 'over_qualified' OR (length(btrim(coalesce(note, ''))) > 0 AND " \
                         "last_role_golongan IS NOT NULL AND last_role_golongan - job_golongan >= 2)",
                         name: "label_confirmations_over_qualified_rule"
    execute <<~SQL
      CREATE FUNCTION enforce_label_confirmation() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        actual_golongan integer;
        result_participation bigint;
      BEGIN
        SELECT participation_id INTO result_participation FROM screening_results WHERE id = NEW.screening_result_id;
        IF result_participation IS DISTINCT FROM NEW.participation_id THEN
          RAISE EXCEPTION 'label confirmation refused: the result belongs to another participation'
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT jobs.golongan INTO actual_golongan
          FROM participations JOIN stages ON stages.id = participations.stage_id JOIN jobs ON jobs.id = stages.job_id
          WHERE participations.id = NEW.participation_id;
        IF actual_golongan IS DISTINCT FROM NEW.job_golongan THEN
          RAISE EXCEPTION 'label confirmation refused: job_golongan must be the job''s Golongan'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    triggers_for(:screening_label_confirmations)
    # Same reviewer rule as feature 06's Review Screening: role reviewer, never the job's consultant.
    execute "CREATE TRIGGER screening_label_confirmations_reviewer BEFORE INSERT ON screening_label_confirmations " \
            "FOR EACH ROW EXECUTE FUNCTION enforce_screening_reviewer();"
    execute "CREATE TRIGGER screening_label_confirmations_rules BEFORE INSERT ON screening_label_confirmations " \
            "FOR EACH ROW EXECUTE FUNCTION enforce_label_confirmation();"
  end

  def create_narrative_approvals
    create_table :screening_narrative_approvals do |t|
      # No foreign key to screening_results (same reason as above); the trigger checks existence.
      t.references :screening_result, null: false, foreign_key: false, index: { unique: true }
      t.bigint :approved_by_id, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_foreign_key :screening_narrative_approvals, :users, column: :approved_by_id
    execute <<~SQL
      CREATE FUNCTION enforce_narrative_approver() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        approver_role text;
        job_consultant bigint;
      BEGIN
        SELECT role INTO approver_role FROM users WHERE id = NEW.approved_by_id;
        IF NOT EXISTS (SELECT 1 FROM screening_results WHERE id = NEW.screening_result_id) THEN
          RAISE EXCEPTION 'narrative approval refused: no such screening result'
            USING ERRCODE = 'check_violation';
        END IF;
        IF approver_role IS DISTINCT FROM 'consultant' THEN
          RAISE EXCEPTION 'narrative approval refused: user % is not a consultant', NEW.approved_by_id
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT jobs.consultant_id INTO job_consultant
          FROM screening_results JOIN participations ON participations.id = screening_results.participation_id
          JOIN stages ON stages.id = participations.stage_id JOIN jobs ON jobs.id = stages.job_id
          WHERE screening_results.id = NEW.screening_result_id;
        IF job_consultant IS NOT NULL AND job_consultant <> NEW.approved_by_id THEN
          RAISE EXCEPTION 'narrative approval refused: only the job''s consultant approves'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    triggers_for(:screening_narrative_approvals)
    execute "CREATE TRIGGER screening_narrative_approvals_consultant BEFORE INSERT ON screening_narrative_approvals " \
            "FOR EACH ROW EXECUTE FUNCTION enforce_narrative_approver();"
  end

  def create_user_recommendations
    create_table :user_recommendations do |t|
      t.references :job_application, null: false, foreign_key: true
      t.string :user_name, null: false
      t.string :pick, null: false
      t.text :note
      t.bigint :entered_by_id, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :user_recommendations, :users, column: :entered_by_id
    add_check_constraint :user_recommendations, "pick IN ('lanjut', 'tidak_lanjut')", name: "user_recommendations_pick"
    add_check_constraint :user_recommendations, "length(btrim(user_name)) > 0", name: "user_recommendations_user_named"
    execute <<~SQL
      CREATE FUNCTION enforce_user_recommendation_actor() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT role FROM users WHERE id = NEW.entered_by_id) IS DISTINCT FROM 'hr_pic' THEN
          RAISE EXCEPTION 'user recommendation refused: only the HR PIC enters it (D62 h6)'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    triggers_for(:user_recommendations)
    execute "CREATE TRIGGER user_recommendations_hr_pic BEFORE INSERT ON user_recommendations " \
            "FOR EACH ROW EXECUTE FUNCTION enforce_user_recommendation_actor();"
  end

  # Append-only like every scoring record (forbid_update_delete / forbid_truncate exist since
  # migration 20261001000002).
  def triggers_for(table)
    execute "CREATE TRIGGER #{table}_append_only BEFORE DELETE OR UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
    execute "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
  end

  def quoted(values) = values.map { |v| "'#{v}'" }.join(", ")
end
