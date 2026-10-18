# D60 slices 3-5 (the online-test plan, Part 1 §b, §d, §e, §a.2, §c scoring). Additive: new columns on test_attempts, one new table, new functions and triggers,
# one partial unique index. Nothing existing is dropped; the slice-2 function enforce_test_attempt is
# REPLACED with a superset (every slice-2 refusal is kept word for word, new ones are added).
#
#   test_attempts (+)   the candidate's answer: when it arrived, the blob, its detected kind, SHA-256,
#                       size, scan state, and the upload grace in force (seconds, recorded per attempt
#                       so a later change of the constant never rewrites what a candidate was given).
#   test_reviews        the reviewer's rubric scoring of one answer (append-only), linked to the
#                       ScoreEntry and Decision it produced; the reviewer is a reviewer and never the
#                       job's consultant (same rule and trigger shape as screening_reviews, feature 06).
#
# Timer rules held by the database (the services enforce the same, the database is the last line):
#   - due_at = started_at + the version's time limit, exactly (the server is the clock authority;
#     nothing the browser sends can lengthen a test).
#   - a test starts no later than 48 hours after the application was submitted
#     (coalesce(consent_at, created_at) + 48 h; consent_at is the submit instant written by Lamar).
#   - a test does not start on a participation that already has a current decision (knockout,
#     no-show, gate_eliminated) or whose attendance is no longer pending.
#   - the answer arrives at most grace_seconds after due_at (2 minutes, network slack), and is set
#     once: never replaced, never removed, its attachment never changes.
class CreateTechnicalTestFlow < ActiveRecord::Migration[8.1]
  def up
    change_table :test_attempts, bulk: true do |t|
      t.datetime :answered_at
      t.bigint :answer_blob_id
      t.string :answer_kind
      t.string :answer_sha256
      t.bigint :answer_bytes
      t.string :answer_scan_state
      # Seconds, not minutes. 120 = plan §b "2 min grace (network slack, recorded)".
      t.integer :grace_seconds, null: false, default: 120
    end
    add_check_constraint :test_attempts, "grace_seconds BETWEEN 0 AND 600", name: "test_attempts_grace_range"
    add_check_constraint :test_attempts,
                         "num_nulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state) IN (0, 6)",
                         name: "test_attempts_answer_complete"
    add_check_constraint :test_attempts,
                         "answered_at IS NULL OR (answered_at >= started_at AND answered_at <= due_at + make_interval(secs => grace_seconds))",
                         name: "test_attempts_answer_in_time"
    add_check_constraint :test_attempts, "answer_kind IS NULL OR answer_kind IN ('xlsx','docx','pdf','csv')",
                         name: "test_attempts_answer_kind"
    # 10 MB = 10,485,760 bytes, inclusive (plan §d "10 MB answer").
    add_check_constraint :test_attempts, "answer_bytes IS NULL OR answer_bytes BETWEEN 1 AND 10485760",
                         name: "test_attempts_answer_max_10_mb"
    add_check_constraint :test_attempts,
                         "answer_scan_state IS NULL OR answer_scan_state IN ('pending_scan','clean','scan_unavailable')",
                         name: "test_attempts_answer_scan_state"

    create_table :test_reviews do |t|
      t.references :participation, null: false, foreign_key: true, index: { unique: true }
      t.references :test_attempt, null: false, foreign_key: true
      t.references :reviewer, null: false, foreign_key: { to_table: :users }
      t.references :score_entry, null: false, foreign_key: true
      t.references :decision, null: false, foreign_key: true
      t.jsonb :ratings, null: false
      t.text :note
      t.datetime :created_at, null: false
    end

    # One notice of each technical-test kind per application (plan §e: one reminder, one receipt, one
    # gate notice). A failed send stays a failed row in the work queue and is not retried by the tick.
    add_index :mail_deliveries, %i[job_application_id kind], unique: true,
              where: "kind IN ('application_received','test_reminder','test_receipt','gate_outcome')",
              name: "mail_deliveries_one_test_notice"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_test_attempt() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE case_row test_cases%ROWTYPE; stage_row stages%ROWTYPE; part_row participations%ROWTYPE;
              submitted timestamp;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'test_attempts: a started test is a fact and is never deleted' USING ERRCODE = 'restrict_violation';
        END IF;
        IF TG_OP = 'UPDATE' THEN
          IF NEW.participation_id <> OLD.participation_id OR NEW.test_case_id <> OLD.test_case_id
             OR NEW.started_at <> OLD.started_at OR NEW.due_at <> OLD.due_at THEN
            RAISE EXCEPTION 'test_attempts: version, start and due time never change' USING ERRCODE = 'restrict_violation';
          END IF;
          IF NEW.grace_seconds <> OLD.grace_seconds THEN
            RAISE EXCEPTION 'test_attempts: the recorded grace never changes' USING ERRCODE = 'restrict_violation';
          END IF;
          IF OLD.answered_at IS NOT NULL AND (
               NEW.answered_at IS DISTINCT FROM OLD.answered_at OR NEW.answer_blob_id IS DISTINCT FROM OLD.answer_blob_id
               OR NEW.answer_kind IS DISTINCT FROM OLD.answer_kind OR NEW.answer_sha256 IS DISTINCT FROM OLD.answer_sha256
               OR NEW.answer_bytes IS DISTINCT FROM OLD.answer_bytes OR NEW.answer_scan_state IS DISTINCT FROM OLD.answer_scan_state) THEN
            RAISE EXCEPTION 'test_attempts: the answer is final once sent' USING ERRCODE = 'restrict_violation';
          END IF;
          IF NEW.answered_at IS NOT NULL AND OLD.answered_at IS NULL THEN
            SELECT * INTO case_row FROM test_cases WHERE id = NEW.test_case_id;
            IF NOT (NEW.answer_kind = ANY (case_row.answer_types)) THEN
              RAISE EXCEPTION 'test_attempts: answer type % is not allowed by version %', NEW.answer_kind, case_row.version
                USING ERRCODE = 'restrict_violation';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM active_storage_attachments att
                           WHERE att.record_type = 'TestAttempt' AND att.record_id = NEW.id AND att.name = 'answer_file'
                             AND att.blob_id = NEW.answer_blob_id) THEN
              RAISE EXCEPTION 'test_attempts: the attached answer is not the one recorded' USING ERRCODE = 'restrict_violation';
            END IF;
          END IF;
          RETURN NEW;
        END IF;
        -- INSERT: the start of a test.
        SELECT * INTO case_row FROM test_cases WHERE id = NEW.test_case_id;
        SELECT * INTO part_row FROM participations WHERE id = NEW.participation_id;
        SELECT st.* INTO stage_row FROM stages st WHERE st.id = part_row.stage_id;
        IF case_row.approved_at IS NULL THEN
          RAISE EXCEPTION 'test_attempts: only an approved test version can be started' USING ERRCODE = 'restrict_violation';
        END IF;
        IF stage_row.code <> 'S2' OR stage_row.job_id <> case_row.job_id THEN
          RAISE EXCEPTION 'test_attempts: the version belongs to another job or the participation is not the technical test'
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.answered_at IS NOT NULL THEN
          RAISE EXCEPTION 'test_attempts: a test starts without an answer' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.due_at <> NEW.started_at + make_interval(mins => case_row.time_limit_minutes) THEN
          RAISE EXCEPTION 'test_attempts: due_at must be started_at + % minutes', case_row.time_limit_minutes
            USING ERRCODE = 'restrict_violation';
        END IF;
        SELECT coalesce(a.consent_at, a.created_at) INTO submitted FROM job_applications a WHERE a.id = part_row.job_application_id;
        IF NEW.started_at > submitted + interval '48 hours' THEN
          RAISE EXCEPTION 'test_attempts: the 48-hour start window has passed' USING ERRCODE = 'restrict_violation';
        END IF;
        IF part_row.attendance <> 'pending' THEN
          RAISE EXCEPTION 'test_attempts: attendance is %, a test starts only from pending', part_row.attendance
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM decisions d WHERE d.participation_id = NEW.participation_id
                     AND NOT EXISTS (SELECT 1 FROM decisions s WHERE s.supersedes_id = d.id)) THEN
          RAISE EXCEPTION 'test_attempts: the participation is already decided' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      -- The answer file belongs to its attempt: once the answer is recorded, its attachment row is
      -- never replaced or removed (an attach deletes and re-inserts the row, so guard the table).
      CREATE FUNCTION enforce_test_answer_file_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE target active_storage_attachments%ROWTYPE;
      BEGIN
        target := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
        IF target.record_type = 'TestAttempt'
           AND EXISTS (SELECT 1 FROM test_attempts a WHERE a.id = target.record_id AND a.answered_at IS NOT NULL) THEN
          RAISE EXCEPTION 'active_storage_attachments: a sent test answer never changes' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;
      CREATE TRIGGER test_answer_file_freeze BEFORE INSERT OR UPDATE OR DELETE ON active_storage_attachments
      FOR EACH ROW EXECUTE FUNCTION enforce_test_answer_file_freeze();

      -- Plan §c / D60 16:45: the technical test is scored by a Reviewer, never by the job's
      -- consultant (the consultant is paid by the job's progress: load-bearing-tests rule 19).
      -- The review must belong to an answered attempt of the same participation.
      CREATE FUNCTION enforce_test_reviewer() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE reviewer_role text; job_consultant bigint; attempt_row test_attempts%ROWTYPE;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'test_reviews is append-only' USING ERRCODE = 'restrict_violation';
        END IF;
        SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewer_id;
        IF reviewer_role IS DISTINCT FROM 'reviewer' THEN
          RAISE EXCEPTION 'test review refused: user % is not a reviewer', NEW.reviewer_id USING ERRCODE = 'restrict_violation';
        END IF;
        SELECT jobs.consultant_id INTO job_consultant
          FROM participations p JOIN stages st ON st.id = p.stage_id JOIN jobs ON jobs.id = st.job_id
         WHERE p.id = NEW.participation_id;
        IF job_consultant IS NOT NULL AND job_consultant = NEW.reviewer_id THEN
          RAISE EXCEPTION 'test review refused: the reviewer is the job''s consultant' USING ERRCODE = 'restrict_violation';
        END IF;
        SELECT * INTO attempt_row FROM test_attempts WHERE id = NEW.test_attempt_id;
        IF attempt_row.participation_id IS DISTINCT FROM NEW.participation_id OR attempt_row.answered_at IS NULL THEN
          RAISE EXCEPTION 'test review refused: no answer was sent for this participation' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM score_entries se WHERE se.id = NEW.score_entry_id
                         AND se.participation_id = NEW.participation_id AND se.entered_by_id = NEW.reviewer_id) THEN
          RAISE EXCEPTION 'test review refused: the score entry is not this reviewer''s entry for this participation'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER test_reviews_reviewer_not_consultant BEFORE INSERT OR UPDATE OR DELETE ON test_reviews
      FOR EACH ROW EXECUTE FUNCTION enforce_test_reviewer();
      CREATE TRIGGER test_reviews_no_truncate BEFORE TRUNCATE ON test_reviews
      FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

      -- A score on an ANSWERED gated technical test comes only from a reviewer who is not the job's
      -- consultant. Scoped narrowly on purpose: only participations with an answered attempt on a
      -- gated stage, so the scoring-core and gate tests that write S2 scores directly (no attempt)
      -- keep their meaning. Same rule as test_reviews, held on the score itself.
      CREATE FUNCTION enforce_test_score_author() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE author_role text; job_consultant bigint;
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM test_attempts a JOIN participations p ON p.id = a.participation_id
                         JOIN stages st ON st.id = p.stage_id
                        WHERE a.participation_id = NEW.participation_id AND a.answered_at IS NOT NULL AND st.gate IS NOT NULL) THEN
          RETURN NEW;
        END IF;
        SELECT role INTO author_role FROM users WHERE id = NEW.entered_by_id;
        SELECT jobs.consultant_id INTO job_consultant
          FROM participations p JOIN stages st ON st.id = p.stage_id JOIN jobs ON jobs.id = st.job_id
         WHERE p.id = NEW.participation_id;
        IF author_role IS DISTINCT FROM 'reviewer' OR (job_consultant IS NOT NULL AND job_consultant = NEW.entered_by_id) THEN
          RAISE EXCEPTION 'score_entries: a technical test answer is scored by a reviewer who is not the job''s consultant'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER score_entries_test_score_author BEFORE INSERT ON score_entries
      FOR EACH ROW EXECUTE FUNCTION enforce_test_score_author();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
