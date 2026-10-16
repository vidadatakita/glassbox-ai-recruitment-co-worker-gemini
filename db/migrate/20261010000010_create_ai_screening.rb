# Feature 06, S1 AI screening (decision D50; blueprint §4.1 steps 1-10, §4.2, §4.3, §5.1 row 2,
# §5.2). Additive only: nullable columns on existing tables and four new append-only tables.
#
# Where each spec line lands:
# - §2.1 Application "extracted CV text"         -> job_applications.cv_text (+ source, when, who)
# - §2.1 Participation "screening state"         -> participations.screening_state (+ failure kind)
# - §4.1 step 9 "model identifier, prompt version" -> score_entries.model_id / prompt_version
# - §4.1 steps 4-6 per-criterion judgements      -> screening_results (append-only)
# - §4.3 retries and failures                    -> screening_attempts (append-only)
# - §4.1 step 7 / D13 calibration                -> calibration_judgements (append-only)
# - §4.1 step 8 reviewer                         -> screening_reviews (append-only, reviewer is
#                                                   never the job's consultant: trigger below)
# - §1.2 "the job's consultant"                  -> jobs.consultant_id (no such link existed)
class CreateAiScreening < ActiveRecord::Migration[8.1]
  def up
    change_table :jobs, bulk: true do |t|
      # The consultant who runs this job (blueprint §1.2). Nullable: jobs created before feature 06
      # and the scoring-test jobs have none. While it is NULL no reviewer is excluded by identity;
      # the role check still applies (feature record 06 §8).
      t.references :consultant, foreign_key: { to_table: :users }
      # Seed of the reproducible 10% pass sample (Screening::ReviewSample). Set once, by the system,
      # the first time a pass needs sampling; never shown on a screen and never edited.
      t.string :screening_sample_seed
    end

    change_table :job_applications, bulk: true do |t|
      # Text extracted from the CV PDF, or pasted by a consultant when the PDF has no text layer
      # (§4.3 "CV tidak terbaca"). Personal data under UU PDP: never logged (ONP-19).
      t.text :cv_text
      t.string :cv_text_source
      t.datetime :cv_text_at
      t.bigint :cv_text_by_id
    end
    add_check_constraint :job_applications, "cv_text_source IS NULL OR cv_text_source IN ('pdf','pasted')",
                         name: "job_applications_cv_text_source"
    add_check_constraint :job_applications, "cv_text_source <> 'pasted' OR cv_text_by_id IS NOT NULL",
                         name: "job_applications_pasted_cv_has_actor"

    change_table :participations, bulk: true do |t|
      # NULL = screening has not been asked for (not an AI stage, AI not active, knockout, ...).
      t.string :screening_state
      # Why the last run failed: timeout / api_error / malformed / refusal / rejected / config.
      t.string :screening_failure
      # Short detail for staff, never CV text: the refusal category or the HTTP status.
      t.string :screening_failure_detail
      t.datetime :screening_state_at
    end
    add_check_constraint :participations,
                         "screening_state IS NULL OR screening_state IN ('queued','done','screening_failed','cv_unreadable')",
                         name: "participations_screening_state"

    change_table :score_entries, bulk: true do |t|
      t.string :model_id
      t.string :prompt_version
    end
    add_check_constraint :score_entries, "(model_id IS NULL) = (prompt_version IS NULL)",
                         name: "score_entries_ai_trace_complete"
    # The AI has no user row, so its entries carry entered_by_id 0 (Screening::AI_ACTOR_ID). Only an
    # entry that names its model may use that id, so a person's entry can never pose as the AI's
    # and an AI entry can never be anonymous about which model produced it.
    add_check_constraint :score_entries, "entered_by_id <> 0 OR model_id IS NOT NULL",
                         name: "score_entries_ai_actor_names_model"

    create_table :screening_results do |t|
      t.references :participation, null: false, foreign_key: true
      t.references :score_entry, foreign_key: true
      # SHA-256 of the rubric sent (the job's requirements). A result whose digest differs from the
      # job's current rubric is stale: the rubric changed after it was produced.
      t.string :rubric_digest, null: false
      # The model that ANSWERED (response.model), which differs from the setting when the server-side
      # refusal fallback ran.
      t.string :model_id, null: false
      t.string :prompt_version, null: false
      # [{ "requirement_id", "tier", "text", "judgement", "quote", "verified" }]
      t.jsonb :judgements, null: false
      # 0-100, one decimal (blueprint §2.2 rule 1); computed in Ruby (Screening::Score).
      t.decimal :score, precision: 4, scale: 1, null: false
      t.boolean :wajib_met, null: false
      t.integer :unverified_count, null: false
      # Nilai tambah: display only (no bonus formula in the spec). Points earned and points possible
      # on the 0-3 scale, e.g. 4 of 6.
      t.integer :bonus_points, null: false, default: 0
      t.integer :bonus_possible, null: false, default: 0
      # Position of this result among the job's passing results (1-based) and whether it fell in the
      # reproducible 10% sample (§4.1 step 8). NULL ordinal when the result did not pass.
      t.integer :pass_ordinal
      t.boolean :sampled, null: false, default: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.datetime :created_at, null: false
    end
    add_check_constraint :screening_results, "score >= 0 AND score <= 100", name: "screening_results_score_range"

    create_table :screening_attempts do |t|
      t.references :participation, null: false, foreign_key: true
      t.integer :attempt, null: false
      t.string :outcome, null: false
      t.string :error_kind
      t.string :detail
      t.datetime :created_at, null: false
    end
    add_check_constraint :screening_attempts, "outcome IN ('succeeded','failed','cv_unreadable')",
                         name: "screening_attempts_outcome"

    create_table :calibration_judgements do |t|
      t.references :job, null: false, foreign_key: true
      t.references :participation, null: false, foreign_key: true
      t.string :rubric_digest, null: false
      t.string :outcome, null: false
      t.text :note
      t.references :judged_by, null: false, foreign_key: { to_table: :users }
      t.datetime :created_at, null: false
    end
    add_check_constraint :calibration_judgements, "outcome IN ('pass','eliminate')", name: "calibration_judgements_outcome"
    add_index :calibration_judgements, %i[participation_id rubric_digest], unique: true,
              name: "index_calibration_judgements_once_per_rubric"

    create_table :screening_reviews do |t|
      t.references :participation, null: false, foreign_key: true
      t.references :screening_result, null: false, foreign_key: true, index: { unique: true }
      t.references :reviewer, null: false, foreign_key: { to_table: :users }
      t.string :verdict, null: false
      t.string :reason, null: false
      t.text :note
      t.references :decision, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end
    add_check_constraint :screening_reviews, "verdict IN ('confirm','reverse')", name: "screening_reviews_verdict"
    add_check_constraint :screening_reviews, "reason IN ('elimination','sample','unverified','calibration_disagreement')",
                         name: "screening_reviews_reason"
    add_check_constraint :screening_reviews, "verdict <> 'reverse' OR length(btrim(coalesce(note, ''))) > 0",
                         name: "screening_reviews_reverse_has_note"

    %w[screening_results screening_attempts calibration_judgements screening_reviews].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
        CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
      SQL
    end

    # Blueprint §1.2 and §4.1 step 8: the reviewer is a reviewer, and never the job's consultant
    # (the consultant is paid by the job's progress; load-bearing-tests rule 19, actor who
    # benefits). Enforced here as well as in Screening::Review, because a model check can be
    # bypassed by any other code path that inserts a review.
    execute <<~SQL
      CREATE FUNCTION enforce_screening_reviewer() RETURNS trigger
        LANGUAGE plpgsql AS $$
      DECLARE
        reviewer_role text;
        job_consultant bigint;
      BEGIN
        SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewer_id;
        IF reviewer_role IS DISTINCT FROM 'reviewer' THEN
          RAISE EXCEPTION 'screening review refused: user % is not a reviewer', NEW.reviewer_id
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT jobs.consultant_id INTO job_consultant
          FROM participations
          JOIN stages ON stages.id = participations.stage_id
          JOIN jobs ON jobs.id = stages.job_id
          WHERE participations.id = NEW.participation_id;
        IF job_consultant IS NOT NULL AND job_consultant = NEW.reviewer_id THEN
          RAISE EXCEPTION 'screening review refused: the reviewer is the job''s consultant'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER screening_reviews_reviewer_not_consultant BEFORE INSERT ON screening_reviews
        FOR EACH ROW EXECUTE FUNCTION enforce_screening_reviewer();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS screening_reviews_reviewer_not_consultant ON screening_reviews"
    execute "DROP FUNCTION IF EXISTS enforce_screening_reviewer()"
    drop_table :screening_reviews
    drop_table :calibration_judgements
    drop_table :screening_attempts
    drop_table :screening_results
    remove_check_constraint :score_entries, name: "score_entries_ai_actor_names_model"
    remove_check_constraint :score_entries, name: "score_entries_ai_trace_complete"
    remove_columns :score_entries, :model_id, :prompt_version
    remove_check_constraint :participations, name: "participations_screening_state"
    remove_columns :participations, :screening_state, :screening_failure, :screening_failure_detail, :screening_state_at
    remove_check_constraint :job_applications, name: "job_applications_pasted_cv_has_actor"
    remove_check_constraint :job_applications, name: "job_applications_cv_text_source"
    remove_columns :job_applications, :cv_text, :cv_text_source, :cv_text_at, :cv_text_by_id
    remove_reference :jobs, :consultant, foreign_key: { to_table: :users }
    remove_column :jobs, :screening_sample_seed
  end
end
