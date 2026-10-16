# Technical test answers for programmers: a link to the candidate's repository (GitHub, GitLab or
# Bitbucket) as an answer type, "repo_link", beside the files. A link answer has no file: the
# completeness check accepts EITHER the six file columns OR answered_at + kind repo_link + a URL of
# that exact shape, never a mix; the answer stays final once sent (answer_url joins the freeze);
# the attached-file check is skipped only for repo_link. The app never fetches the link; the
# reviewer opens it.
class AllowRepoLinkAnswers < ActiveRecord::Migration[8.1]
  FILE_TYPES = "'xlsx','docx','pdf','csv'".freeze
  ALL_TYPES = "'xlsx','docx','pdf','csv','repo_link'".freeze
  # Same shape as TechnicalTests::SubmitAnswer::REPO_URL (owner/repo, then an optional path).
  REPO_URL = "^https://(github\\.com|gitlab\\.com|bitbucket\\.org)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^[:space:]]*)?$".freeze

  def up
    add_column :test_attempts, :answer_url, :string

    execute <<~SQL
      ALTER TABLE test_cases DROP CONSTRAINT test_cases_answer_types;
      ALTER TABLE test_cases ADD CONSTRAINT test_cases_answer_types CHECK (answer_types <@ ARRAY[#{ALL_TYPES}]::varchar[]);
      ALTER TABLE test_attempts DROP CONSTRAINT test_attempts_answer_kind;
      ALTER TABLE test_attempts ADD CONSTRAINT test_attempts_answer_kind CHECK (answer_kind IS NULL OR answer_kind IN (#{ALL_TYPES}));
      ALTER TABLE test_attempts DROP CONSTRAINT test_attempts_answer_complete;
      ALTER TABLE test_attempts ADD CONSTRAINT test_attempts_answer_complete CHECK (
        (num_nonnulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state, answer_url) = 0)
        OR (answer_kind <> 'repo_link' AND answer_url IS NULL
            AND num_nulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state) = 0)
        OR (answer_kind = 'repo_link' AND answered_at IS NOT NULL AND answer_url ~ '#{REPO_URL}'
            AND num_nonnulls(answer_blob_id, answer_sha256, answer_bytes, answer_scan_state) = 0)
      );
    SQL
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
               OR NEW.answer_bytes IS DISTINCT FROM OLD.answer_bytes OR NEW.answer_scan_state IS DISTINCT FROM OLD.answer_scan_state
               OR NEW.answer_url IS DISTINCT FROM OLD.answer_url) THEN
            RAISE EXCEPTION 'test_attempts: the answer is final once sent' USING ERRCODE = 'restrict_violation';
          END IF;
          IF NEW.answered_at IS NOT NULL AND OLD.answered_at IS NULL THEN
            SELECT * INTO case_row FROM test_cases WHERE id = NEW.test_case_id;
            IF NOT (NEW.answer_kind = ANY (case_row.answer_types)) THEN
              RAISE EXCEPTION 'test_attempts: answer type % is not allowed by version %', NEW.answer_kind, case_row.version
                USING ERRCODE = 'restrict_violation';
            END IF;
            -- A repository link has no file; every other answer is the attached file.
            IF NEW.answer_kind <> 'repo_link' AND NOT EXISTS (SELECT 1 FROM active_storage_attachments att
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
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE test_attempts DROP CONSTRAINT test_attempts_answer_complete;
      ALTER TABLE test_attempts ADD CONSTRAINT test_attempts_answer_complete CHECK (num_nulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state) IN (0, 6));
      ALTER TABLE test_attempts DROP CONSTRAINT test_attempts_answer_kind;
      ALTER TABLE test_attempts ADD CONSTRAINT test_attempts_answer_kind CHECK (answer_kind IS NULL OR answer_kind IN (#{FILE_TYPES}));
      ALTER TABLE test_cases DROP CONSTRAINT test_cases_answer_types;
      ALTER TABLE test_cases ADD CONSTRAINT test_cases_answer_types CHECK (answer_types <@ ARRAY[#{FILE_TYPES}]::varchar[]);
    SQL
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
    SQL
    remove_column :test_attempts, :answer_url
  end
end
