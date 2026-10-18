# D60 slice 2: the technical test
# of a job, versioned. Additive: three new tables, functions and triggers; nothing existing changes.
#
#   test_cases          one row per version of a job's test: case file (ActiveStorage, private),
#                       instructions (Bahasa), time limit (minutes, default 35, at most 60), the
#                       answer file types allowed, who created it and when, who approved it and when.
#   test_case_criteria  the rubric of a version: each criterion has a weight (whole %, the version's
#                       weights sum to 100 before approval), the 1/3/5 anchors, and the job activity
#                       it tests (id plus a copy of the activity text, so a later brief edit never
#                       changes what a started test was built from).
#   test_attempts       the STARTED MARKER: one row per S2 participation that started a version.
#                       Slice 3 (the candidate test flow) writes it; this migration only creates it
#                       and its guards, so the freeze below already holds when slice 3 lands.
#
# Lifecycle and the database guards (each repeats a rule the services enforce):
#   - A version is a DRAFT until HR PIC approves it. A draft may be edited in place by the
#     consultant (every save is an audit row in job_brief_changes). Approval needs a case file
#     whose attachment points at the recorded blob, a scan state that is not "infected", and
#     criteria whose weights sum to exactly 100; the approver must have role hr_pic.
#   - An APPROVED version never changes: content, criteria, case file and the approval itself.
#     A change is a new version (n + 1), which must state a reason.
#   - A STARTED version (a test_attempts row exists) never changes, checked FIRST and with its own
#     message: this is the lock candidates rely on ("the rubric of a started version never
#     changes", plan §c), independent of the approval rule above.
#   - Versions and attempts are never deleted (no DELETE, no TRUNCATE).
#   - An attempt starts only on an APPROVED version of the participation's own job, on S2, and
#     its version, start and due time never change (each candidate keeps the version they started).
class CreateTestCases < ActiveRecord::Migration[8.1]
  def up
    create_table :test_cases do |t|
      t.references :job, null: false, foreign_key: true
      t.integer :version, null: false
      t.text :instructions, null: false, default: ""
      t.integer :time_limit_minutes, null: false, default: 35
      t.string :answer_types, array: true, null: false, default: []
      t.text :new_version_reason
      t.bigint :case_file_blob_id
      t.string :case_file_kind
      t.string :case_file_sha256
      t.bigint :case_file_bytes
      t.string :scan_state
      t.datetime :scanned_at
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.timestamps
    end
    add_index :test_cases, %i[job_id version], unique: true
    add_check_constraint :test_cases, "version >= 1", name: "test_cases_version_positive"
    add_check_constraint :test_cases, "time_limit_minutes BETWEEN 1 AND 60", name: "test_cases_time_limit_max_60"
    add_check_constraint :test_cases, "answer_types <@ ARRAY['xlsx','docx','pdf','csv']::varchar[]", name: "test_cases_answer_types"
    add_check_constraint :test_cases, "case_file_kind IS NULL OR case_file_kind IN ('xlsx','docx','pdf','csv')",
                         name: "test_cases_case_file_kind"
    add_check_constraint :test_cases, "case_file_bytes IS NULL OR case_file_bytes BETWEEN 1 AND 20971520",
                         name: "test_cases_case_file_max_20_mb"
    add_check_constraint :test_cases, "scan_state IS NULL OR scan_state IN ('pending_scan','clean','infected','scan_unavailable')",
                         name: "test_cases_scan_state"
    add_check_constraint :test_cases, "version = 1 OR length(btrim(coalesce(new_version_reason, ''))) > 0",
                         name: "test_cases_new_version_has_reason"
    add_check_constraint :test_cases, "(approved_at IS NULL) = (approved_by_id IS NULL)", name: "test_cases_approval_pair"
    add_check_constraint :test_cases,
                         "approved_at IS NULL OR (case_file_blob_id IS NOT NULL AND scan_state IS NOT NULL AND scan_state <> 'infected' " \
                         "AND cardinality(answer_types) >= 1 AND length(btrim(instructions)) > 0)",
                         name: "test_cases_approved_is_complete"

    create_table :test_case_criteria do |t|
      t.references :test_case, null: false, foreign_key: true
      t.integer :position, null: false
      t.bigint :activity_id
      t.text :activity_text, null: false
      t.text :name, null: false
      t.integer :weight, null: false
      t.text :anchor_1, null: false
      t.text :anchor_3, null: false
      t.text :anchor_5, null: false
      t.timestamps
    end
    add_index :test_case_criteria, %i[test_case_id position], unique: true
    add_check_constraint :test_case_criteria, "weight BETWEEN 1 AND 100", name: "test_case_criteria_weight"

    create_table :test_attempts do |t|
      t.references :participation, null: false, foreign_key: true, index: { unique: true }
      t.references :test_case, null: false, foreign_key: true
      t.datetime :started_at, null: false
      t.datetime :due_at, null: false
      t.timestamps
    end
    add_check_constraint :test_attempts, "due_at > started_at", name: "test_attempts_due_after_start"

    execute <<~SQL
      CREATE FUNCTION enforce_test_case_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE approver_role varchar; weight_sum integer; criteria_count integer;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'test_cases: a version is never deleted' USING ERRCODE = 'restrict_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM test_attempts a WHERE a.test_case_id = OLD.id) THEN
          RAISE EXCEPTION 'test_cases: version % has been started by a candidate and is frozen', OLD.version
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.approved_at IS NOT NULL THEN
          RAISE EXCEPTION 'test_cases: version % is approved and final; make a new version', OLD.version
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.job_id <> OLD.job_id OR NEW.version <> OLD.version OR NEW.created_by_id <> OLD.created_by_id THEN
          RAISE EXCEPTION 'test_cases: job, version and creator never change' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.approved_at IS NOT NULL THEN
          SELECT role INTO approver_role FROM users WHERE id = NEW.approved_by_id;
          IF approver_role IS DISTINCT FROM 'hr_pic' THEN
            RAISE EXCEPTION 'test_cases: only HR PIC approves a test version' USING ERRCODE = 'restrict_violation';
          END IF;
          SELECT coalesce(sum(weight), 0), count(*) INTO weight_sum, criteria_count FROM test_case_criteria WHERE test_case_id = NEW.id;
          IF criteria_count = 0 OR weight_sum <> 100 THEN
            RAISE EXCEPTION 'test_cases: rubric weights must sum to 100 before approval (now %)', weight_sum
              USING ERRCODE = 'restrict_violation';
          END IF;
          IF NOT EXISTS (SELECT 1 FROM active_storage_attachments att
                         WHERE att.record_type = 'TestCase' AND att.record_id = NEW.id AND att.name = 'case_file'
                           AND att.blob_id = NEW.case_file_blob_id) THEN
            RAISE EXCEPTION 'test_cases: the attached case file is not the one recorded on the version'
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER test_cases_freeze BEFORE UPDATE OR DELETE ON test_cases
      FOR EACH ROW EXECUTE FUNCTION enforce_test_case_freeze();
      CREATE TRIGGER test_cases_no_truncate BEFORE TRUNCATE ON test_cases
      FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

      -- The rubric and the case file belong to their version: once it is started or approved,
      -- neither changes (an attach on an existing record deletes and re-inserts the attachment row,
      -- so the attachment table is guarded too, not only test_cases).
      CREATE FUNCTION test_case_is_final(case_id bigint) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM test_attempts a WHERE a.test_case_id = case_id)
            OR EXISTS (SELECT 1 FROM test_cases c WHERE c.id = case_id AND c.approved_at IS NOT NULL);
      $$;

      CREATE FUNCTION enforce_test_case_criteria_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF test_case_is_final(CASE WHEN TG_OP = 'INSERT' THEN NEW.test_case_id ELSE OLD.test_case_id END)
           OR (TG_OP = 'UPDATE' AND test_case_is_final(NEW.test_case_id)) THEN
          RAISE EXCEPTION 'test_case_criteria: the rubric of a started or approved version never changes'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;
      CREATE TRIGGER test_case_criteria_freeze BEFORE INSERT OR UPDATE OR DELETE ON test_case_criteria
      FOR EACH ROW EXECUTE FUNCTION enforce_test_case_criteria_freeze();
      CREATE TRIGGER test_case_criteria_no_truncate BEFORE TRUNCATE ON test_case_criteria
      FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

      CREATE FUNCTION enforce_test_case_file_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE target active_storage_attachments%ROWTYPE;
      BEGIN
        target := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
        IF target.record_type = 'TestCase' AND test_case_is_final(target.record_id) THEN
          RAISE EXCEPTION 'active_storage_attachments: the case file of a started or approved test version never changes'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;
      CREATE TRIGGER test_case_file_freeze BEFORE INSERT OR UPDATE OR DELETE ON active_storage_attachments
      FOR EACH ROW EXECUTE FUNCTION enforce_test_case_file_freeze();

      CREATE FUNCTION enforce_test_attempt() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE case_row test_cases%ROWTYPE; stage_row stages%ROWTYPE;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'test_attempts: a started test is a fact and is never deleted' USING ERRCODE = 'restrict_violation';
        END IF;
        IF TG_OP = 'UPDATE' THEN
          IF NEW.participation_id <> OLD.participation_id OR NEW.test_case_id <> OLD.test_case_id
             OR NEW.started_at <> OLD.started_at OR NEW.due_at <> OLD.due_at THEN
            RAISE EXCEPTION 'test_attempts: version, start and due time never change' USING ERRCODE = 'restrict_violation';
          END IF;
          RETURN NEW;
        END IF;
        SELECT * INTO case_row FROM test_cases WHERE id = NEW.test_case_id;
        SELECT st.* INTO stage_row FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
        IF case_row.approved_at IS NULL THEN
          RAISE EXCEPTION 'test_attempts: only an approved test version can be started' USING ERRCODE = 'restrict_violation';
        END IF;
        IF stage_row.code <> 'S2' OR stage_row.job_id <> case_row.job_id THEN
          RAISE EXCEPTION 'test_attempts: the version belongs to another job or the participation is not the technical test'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER test_attempts_guard BEFORE INSERT OR UPDATE OR DELETE ON test_attempts
      FOR EACH ROW EXECUTE FUNCTION enforce_test_attempt();
      CREATE TRIGGER test_attempts_no_truncate BEFORE TRUNCATE ON test_attempts
      FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
