SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ai_release_person_allowed(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ai_release_person_allowed(person bigint, release_job bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (SELECT 1 FROM users WHERE id = person AND role IN ('hr_manager', 'superadmin'))
       AND NOT EXISTS (SELECT 1 FROM jobs WHERE id = release_job AND consultant_id = person)
  $$;


--
-- Name: ai_releases_erase_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ai_releases_erase_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ai_releases is append-only: DELETE refused' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.payload_text = '' THEN
    NEW.payload_text := NULL;
  END IF;
  IF NEW.payload_text IS NOT NULL OR (to_jsonb(NEW) - 'payload_text') IS DISTINCT FROM (to_jsonb(OLD) - 'payload_text') THEN
    RAISE EXCEPTION 'ai_releases is append-only: UPDATE refused (the only change allowed is erasing payload_text; the digest never changes)'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.payload_text IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ai_release_erasures WHERE ai_release_id = OLD.id) THEN
    RAISE EXCEPTION 'ai_releases is append-only: UPDATE refused (erasing release % needs an ai_release_erasures row written first)', OLD.id
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_ai_release_action(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_ai_release_action() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  rel ai_releases%ROWTYPE;
BEGIN
  SELECT * INTO rel FROM ai_releases WHERE id = NEW.ai_release_id;
  IF NOT ai_release_person_allowed(NEW.actor_id, rel.job_id) THEN
    RAISE EXCEPTION 'ai release refused: user % is not a reviewer or is the job''s consultant', NEW.actor_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ai_releases r WHERE r.participation_id = rel.participation_id
               AND r.payload_kind = rel.payload_kind AND r.id > rel.id) THEN
    RAISE EXCEPTION 'ai release refused: version % is not the latest', rel.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.action = 'released' THEN
    IF rel.payload_text IS NULL THEN
      RAISE EXCEPTION 'ai release refused: version % is erased', rel.id USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.payload_sha256 IS DISTINCT FROM rel.payload_sha256 THEN
      RAISE EXCEPTION 'ai release refused: digest does not match version %', rel.id
        USING ERRCODE = 'check_violation';
    END IF;
    IF cardinality(rel.residual_categories) > 0 THEN
      RAISE EXCEPTION 'ai release refused: version % still has residual-check findings', rel.id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_ai_release_cut(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_ai_release_cut() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  parent ai_releases%ROWTYPE;
  old_lines text[];
  new_lines text[];
  changed int[] := '{}';
  i int;
BEGIN
  IF NEW.supersedes_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NOT ai_release_person_allowed(NEW.cut_by_id, NEW.job_id) THEN
    RAISE EXCEPTION 'ai release cut refused: user % is not a reviewer or is the job''s consultant', NEW.cut_by_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ai_release_actions WHERE ai_release_id = NEW.supersedes_id) THEN
    RAISE EXCEPTION 'ai release cut refused: version % is already decided', NEW.supersedes_id
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO parent FROM ai_releases WHERE id = NEW.supersedes_id;
  IF parent.payload_text IS NULL OR NEW.payload_text IS NULL THEN
    RAISE EXCEPTION 'ai release cut refused: version % is erased', NEW.supersedes_id USING ERRCODE = 'check_violation';
  END IF;
  IF (NEW.participation_id, NEW.job_id, NEW.payload_kind, NEW.cv_line_start, NEW.cv_line_end, NEW.rubric_digest, NEW.source_sha256)
     IS DISTINCT FROM
     (parent.participation_id, parent.job_id, parent.payload_kind, parent.cv_line_start, parent.cv_line_end, parent.rubric_digest, parent.source_sha256) THEN
    RAISE EXCEPTION 'ai release cut refused: a cut keeps the superseded version''s participation, kind, CV range and digests'
      USING ERRCODE = 'check_violation';
  END IF;
  old_lines := string_to_array(parent.payload_text, E'\n');
  new_lines := string_to_array(NEW.payload_text, E'\n');
  IF coalesce(array_length(old_lines, 1), 0) <> coalesce(array_length(new_lines, 1), 0) THEN
    RAISE EXCEPTION 'ai release cut refused: a cut never adds or removes lines' USING ERRCODE = 'check_violation';
  END IF;
  FOR i IN 1 .. coalesce(array_length(old_lines, 1), 0) LOOP
    IF new_lines[i] IS DISTINCT FROM old_lines[i] THEN
      -- 1-based array index i = 0-based payload line i - 1.
      IF new_lines[i] <> '[REDACTED]' OR (i - 1) < parent.cv_line_start OR (i - 1) > parent.cv_line_end THEN
        RAISE EXCEPTION 'ai release cut refused: line % changed to something other than [REDACTED] or outside the CV', i - 1
          USING ERRCODE = 'check_violation';
      END IF;
      changed := changed || (i - 1);
    END IF;
  END LOOP;
  IF cardinality(changed) = 0 OR
     (SELECT array_agg(x ORDER BY x) FROM unnest(changed) x) IS DISTINCT FROM
     (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(NEW.cut_line_numbers) x) THEN
    RAISE EXCEPTION 'ai release cut refused: cut_line_numbers must be exactly the lines replaced by [REDACTED]'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
      $$;


--
-- Name: enforce_application_draft(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_application_draft() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.test_started_at IS NOT NULL AND (NEW.draw <> OLD.draw OR NEW.test_started_at <> OLD.test_started_at
      OR NEW.test_due_at <> OLD.test_due_at OR NEW.time_limit_minutes <> OLD.time_limit_minutes
      OR NEW.question_bank_id <> OLD.question_bank_id OR NEW.grace_seconds <> OLD.grace_seconds) THEN
    RAISE EXCEPTION 'application_drafts: the draw and the deadline never change once the test started'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.submitted_at IS NOT NULL AND (NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
      OR NEW.job_application_id IS DISTINCT FROM OLD.job_application_id) THEN
    RAISE EXCEPTION 'application_drafts: a submitted draft stays linked to its application'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_bank_question_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_bank_question_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE bank_id bigint;
BEGIN
  bank_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.question_bank_id ELSE OLD.question_bank_id END;
  IF EXISTS (SELECT 1 FROM question_banks b WHERE b.id = bank_id AND b.approved_at IS NOT NULL) THEN
    RAISE EXCEPTION 'bank_questions: the bank is approved and final; make a new version' USING ERRCODE = 'restrict_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM question_banks b WHERE b.id = bank_id AND b.submitted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'bank_questions: the bank is submitted for approval; return it to draft before any change'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.question_bank_id <> OLD.question_bank_id THEN
    RAISE EXCEPTION 'bank_questions: a question never moves to another bank' USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_draft_answer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_draft_answer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE d application_drafts%ROWTYPE;
BEGIN
  SELECT * INTO d FROM application_drafts WHERE id = NEW.application_draft_id;
  -- Only the correct flag may be written after submit (the scoring at Submit itself).
  IF TG_OP = 'UPDATE' AND NEW.choice_index IS NOT DISTINCT FROM OLD.choice_index
     AND NEW.answer_text IS NOT DISTINCT FROM OLD.answer_text AND NEW.saved_at = OLD.saved_at THEN
    RETURN NEW;
  END IF;
  IF d.submitted_at IS NOT NULL THEN
    RAISE EXCEPTION 'draft_answers: the application is submitted; answers are final' USING ERRCODE = 'restrict_violation';
  END IF;
  IF d.test_started_at IS NULL OR NOT (NEW.bank_question_id = ANY (d.draw)) THEN
    RAISE EXCEPTION 'draft_answers: only a question drawn for this applicant, after the test started'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.saved_at > d.test_due_at + make_interval(secs => d.grace_seconds) THEN
    RAISE EXCEPTION 'draft_answers: the time for the test is over' USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_draft_answer_review(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_draft_answer_review() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE reviewer_role text; job_consultant bigint;
BEGIN
  IF NEW.reviewed_by_id IS NULL OR NEW.reviewed_by_id IS NOT DISTINCT FROM OLD.reviewed_by_id AND NEW.review_rating IS NOT DISTINCT FROM OLD.review_rating THEN
    RETURN NEW;
  END IF;
  SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewed_by_id;
  SELECT jobs.consultant_id INTO job_consultant FROM application_drafts d JOIN jobs ON jobs.id = d.job_id
   WHERE d.id = NEW.application_draft_id;
  IF COALESCE(reviewer_role, '') NOT IN ('hr_manager', 'superadmin') OR (job_consultant IS NOT NULL AND job_consultant = NEW.reviewed_by_id) THEN
    RAISE EXCEPTION 'draft_answers: a written answer is confirmed by a reviewer who is not the job''s consultant'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_gate_eliminated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_gate_eliminated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE s2 stages%ROWTYPE; application_id bigint;
BEGIN
  IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;
  -- The wrong shape (manual, pass, review) is refused by CHECK decisions_gate_eliminated_is_rule.
  IF NEW.basis <> 'rule' OR NEW.outcome <> 'eliminate' THEN RETURN NEW; END IF;
  SELECT st.* INTO s2 FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
  SELECT p.job_application_id INTO application_id FROM participations p WHERE p.id = NEW.participation_id;
  IF s2.gate IS NULL OR s2.code <> 'S2' THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only on the S2 stage of a gate' USING ERRCODE = 'restrict_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM score_entries se WHERE se.participation_id = NEW.participation_id) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is for a test nobody scored' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM participations p1
       JOIN stages s1 ON s1.id = p1.stage_id AND s1.job_id = s2.job_id AND s1.gate = s2.gate AND s1.code = 'S1'
       JOIN decisions d ON d.participation_id = p1.id
       WHERE p1.job_application_id = application_id AND d.outcome = 'eliminate'
         AND NOT EXISTS (SELECT 1 FROM decisions later WHERE later.supersedes_id = d.id)) THEN
    RAISE EXCEPTION 'decisions: gate_eliminated needs a current S1 elimination of the same application'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NULLIF(current_setting('glassbox.gate_closing', true), '') IS DISTINCT FROM s2.id::text THEN
    RAISE EXCEPTION 'decisions: gate_eliminated is written only while the gate closes (Gates::Close)'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
      $$;


--
-- Name: enforce_gate_status_together(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_gate_status_together() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE cur stages%ROWTYPE; member_count integer;
BEGIN
  -- Read the row as it is NOW (at commit), not as it was when the event was queued.
  SELECT * INTO cur FROM stages WHERE id = NEW.id;
  IF NOT FOUND OR cur.gate IS NULL THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM stages s WHERE s.job_id = cur.job_id AND s.gate = cur.gate
               AND s.id <> cur.id AND s.status <> cur.status) THEN
    RAISE EXCEPTION 'stages: the stages of gate % must open and close together', cur.gate
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF cur.status <> 'draft' THEN
    SELECT count(*) INTO member_count FROM stages s WHERE s.job_id = cur.job_id AND s.gate = cur.gate;
    IF member_count <> 2 THEN
      RAISE EXCEPTION 'stages: gate % needs both S1 and S2 before it opens', cur.gate USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: enforce_label_confirmation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_label_confirmation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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

  IF NEW.label = 'over_qualified' AND NOT EXISTS (
     SELECT 1 FROM screening_results
      WHERE id = NEW.screening_result_id AND (last_position ->> 'verified') = 'true') THEN
  RAISE EXCEPTION 'label confirmation refused: Over-qualified needs a last-position quote found in the CV'
    USING ERRCODE = 'check_violation';
END IF;

  RETURN NEW;
END;
$$;


--
-- Name: enforce_narrative_approver(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_narrative_approver() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  approver_role text;
  job_consultant bigint;
BEGIN
  SELECT role INTO approver_role FROM users WHERE id = NEW.approved_by_id;
  IF NOT EXISTS (SELECT 1 FROM screening_results WHERE id = NEW.screening_result_id) THEN
    RAISE EXCEPTION 'narrative approval refused: no such screening result'
      USING ERRCODE = 'check_violation';
  END IF;
  IF COALESCE(approver_role, '') NOT IN ('hr_admin', 'superadmin') THEN
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


--
-- Name: enforce_progression_chooser(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_progression_chooser() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF COALESCE((SELECT role FROM users WHERE id = NEW.actor_id), '') NOT IN ('hr_admin', 'superadmin') THEN
    RAISE EXCEPTION 'progression choice refused: only the HR PIC chooses (AI Builder Cup step 06)'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT user_in_job_company(NEW.actor_id, (SELECT s.job_id FROM participations p JOIN stages s ON s.id = p.stage_id WHERE p.id = NEW.participation_id)) THEN
    RAISE EXCEPTION 'progression choice refused: the HR PIC belongs to another company' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_question_bank_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_question_bank_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE approver_role varchar; technical_count integer; role_count integer; incomplete integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'question_banks: a version is never deleted' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'question_banks: version % is approved and final; make a new version', OLD.version
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.job_id <> OLD.job_id OR NEW.version <> OLD.version OR NEW.created_by_id <> OLD.created_by_id THEN
    RAISE EXCEPTION 'question_banks: job, version and creator never change' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.submitted_at IS NOT NULL AND NEW.submitted_at IS NOT NULL
     AND (NEW.technical_draw <> OLD.technical_draw OR NEW.role_draw <> OLD.role_draw
          OR NEW.time_limit_minutes <> OLD.time_limit_minutes) THEN
    RAISE EXCEPTION 'question_banks: version % is submitted for approval; return it to draft before changing it', OLD.version
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.approved_at IS NOT NULL THEN
    SELECT role INTO approver_role FROM users WHERE id = NEW.approved_by_id;
    -- NULL-safe on purpose: a missing user must not pass a NOT IN.
    IF COALESCE(approver_role, '') NOT IN ('hr_manager', 'superadmin') THEN
      RAISE EXCEPTION 'question_banks: only the HR Manager approves a question bank' USING ERRCODE = 'restrict_violation';
    END IF;
    IF approver_role <> 'superadmin' AND NEW.approved_by_id IN (NEW.created_by_id, NEW.submitted_by_id) THEN
  RAISE EXCEPTION 'question_banks: the person who created or submitted the bank cannot approve it' USING ERRCODE = 'restrict_violation';
END IF;

    SELECT count(*) FILTER (WHERE section = 'technical'), count(*) FILTER (WHERE section = 'role'),
           count(*) FILTER (WHERE (section = 'technical' AND activity_id IS NULL)
                               OR (section = 'role' AND competency_id IS NULL)
                               OR (kind = 'written' AND (length(btrim(COALESCE(anchor_1, ''))) = 0
                                                         OR length(btrim(COALESCE(anchor_3, ''))) = 0
                                                         OR length(btrim(COALESCE(anchor_5, ''))) = 0)))
      INTO technical_count, role_count, incomplete
      FROM bank_questions WHERE question_bank_id = NEW.id;
    IF technical_count < 2 * NEW.technical_draw OR role_count < 2 * NEW.role_draw THEN
      RAISE EXCEPTION 'question_banks: the bank needs at least twice the draw per section (technical %/% , role %/%)',
        technical_count, 2 * NEW.technical_draw, role_count, 2 * NEW.role_draw USING ERRCODE = 'restrict_violation';
    END IF;
    IF incomplete > 0 THEN
      RAISE EXCEPTION 'question_banks: % question(s) lack their brief link or scoring anchors', incomplete
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_question_bank_inserted_as_draft(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_question_bank_inserted_as_draft() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.approved_at IS NOT NULL OR NEW.approved_by_id IS NOT NULL OR NEW.submitted_at IS NOT NULL THEN
    RAISE EXCEPTION 'question_banks: a version is inserted as a draft; the HR Admin submits it and the HR Manager approves it'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_salary_decider(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_salary_decider() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF COALESCE((SELECT role FROM users WHERE id = NEW.decided_by_id), '') NOT IN ('hr_manager', 'superadmin') THEN
    RAISE EXCEPTION 'salary agreement refused: only the owner decides (AI Builder Cup step 08)'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT user_in_job_company(NEW.decided_by_id, (SELECT job_id FROM job_applications WHERE id = NEW.job_application_id)) THEN
    RAISE EXCEPTION 'salary agreement refused: the owner belongs to another company' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_same_participation_supersede(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_same_participation_supersede() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE target_participation bigint;
BEGIN
  IF NEW.supersedes_id IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT participation_id FROM %I WHERE id = $1', TG_TABLE_NAME)
    INTO target_participation USING NEW.supersedes_id;
  IF target_participation IS DISTINCT FROM NEW.participation_id THEN
    RAISE EXCEPTION '%: a row can supersede only a row of the same participation', TG_TABLE_NAME
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$_$;


--
-- Name: enforce_screening_reviewer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_screening_reviewer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  reviewer_role text;
  job_consultant bigint;
BEGIN
  SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewer_id;
  IF COALESCE(reviewer_role, '') NOT IN ('hr_manager', 'superadmin') THEN
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


--
-- Name: enforce_single_tenant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_single_tenant() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF current_setting('glassbox.tenancy', true) = 'single' THEN
    LOCK TABLE client_companies IN SHARE ROW EXCLUSIVE MODE;
    IF EXISTS (SELECT 1 FROM client_companies) THEN
      RAISE EXCEPTION 'TENANCY=single allows one client company'
        USING ERRCODE = 'unique_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;


--
-- Name: enforce_stage_gate_fixed(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_stage_gate_fixed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.gate IS DISTINCT FROM OLD.gate AND OLD.status <> 'draft' THEN
    RAISE EXCEPTION 'stages: the gate of a stage cannot change once it has opened' USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_stage_lifecycle(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_stage_lifecycle() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE named_change bigint := NULLIF(current_setting('glassbox.stage_change_id', true), '')::bigint;
BEGIN
  IF OLD.opened_at IS NOT NULL AND NEW.opened_at IS DISTINCT FROM OLD.opened_at THEN
    RAISE EXCEPTION 'stages: opened_at cannot change once set' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'draft' AND NEW.status = 'open') OR (OLD.status = 'open' AND NEW.status = 'closed')) THEN
    RAISE EXCEPTION 'stages: status cannot move from % to %', OLD.status, NEW.status USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'closed' AND (NEW.threshold <> OLD.threshold OR NEW.weight <> OLD.weight) THEN
    RAISE EXCEPTION 'stages: tahap sudah ditutup; weight and threshold are final' USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.status = 'open' AND NEW.status = 'closed' AND EXISTS (
       SELECT 1 FROM participations p
       WHERE p.stage_id = NEW.id AND NOT EXISTS (
         SELECT 1 FROM decisions d
         WHERE d.participation_id = p.id AND d.outcome <> 'review'
           AND NOT EXISTS (SELECT 1 FROM decisions s WHERE s.supersedes_id = d.id))) THEN
    RAISE EXCEPTION 'stages: cannot close while a participation is undecided or in review'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF OLD.opened_at IS NOT NULL THEN
    IF NEW.threshold <> OLD.threshold AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'threshold'
           AND sc.old_value = OLD.threshold AND sc.new_value = NEW.threshold
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'threshold')) THEN
      RAISE EXCEPTION 'stages: a locked threshold changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF NEW.weight <> OLD.weight AND NOT EXISTS (
         SELECT 1 FROM stage_changes sc
         WHERE sc.id = named_change AND sc.stage_id = NEW.id AND sc.field = 'weight'
           AND sc.old_value = OLD.weight AND sc.new_value = NEW.weight
           AND sc.id = (SELECT max(id) FROM stage_changes WHERE stage_id = NEW.id AND field = 'weight')) THEN
      RAISE EXCEPTION 'stages: a locked weight changes only with its latest StageChange named in the same transaction'
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
      $$;


--
-- Name: enforce_test_answer_file_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_answer_file_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: enforce_test_attempt(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_attempt() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: enforce_test_case_criteria_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_case_criteria_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF test_case_is_final(CASE WHEN TG_OP = 'INSERT' THEN NEW.test_case_id ELSE OLD.test_case_id END)
     OR (TG_OP = 'UPDATE' AND test_case_is_final(NEW.test_case_id)) THEN
    RAISE EXCEPTION 'test_case_criteria: the rubric of a started or approved version never changes'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: enforce_test_case_file_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_case_file_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE target active_storage_attachments%ROWTYPE;
BEGIN
  target := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
  IF target.record_type = 'TechnicalTestCase' AND test_case_is_final(target.record_id) THEN
    RAISE EXCEPTION 'active_storage_attachments: the case file of a started or approved test version never changes'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


--
-- Name: enforce_test_case_freeze(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_case_freeze() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
    IF COALESCE(approver_role, '') NOT IN ('hr_admin', 'superadmin') THEN
      RAISE EXCEPTION 'test_cases: only HR PIC approves a test version' USING ERRCODE = 'restrict_violation';
    END IF;
    SELECT coalesce(sum(weight), 0), count(*) INTO weight_sum, criteria_count FROM test_case_criteria WHERE test_case_id = NEW.id;
    IF criteria_count = 0 OR weight_sum <> 100 THEN
      RAISE EXCEPTION 'test_cases: rubric weights must sum to 100 before approval (now %)', weight_sum
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM active_storage_attachments att
                   WHERE att.record_type = 'TechnicalTestCase' AND att.record_id = NEW.id AND att.name = 'case_file'
                     AND att.blob_id = NEW.case_file_blob_id) THEN
      RAISE EXCEPTION 'test_cases: the attached case file is not the one recorded on the version'
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_test_case_inserted_as_draft(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_case_inserted_as_draft() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.approved_at IS NOT NULL OR NEW.approved_by_id IS NOT NULL THEN
    RAISE EXCEPTION 'test_cases: a version is inserted as a draft; HR PIC approves it afterwards'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_test_reviewer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_reviewer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE reviewer_role text; job_consultant bigint; attempt_row test_attempts%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'test_reviews is append-only' USING ERRCODE = 'restrict_violation';
  END IF;
  SELECT role INTO reviewer_role FROM users WHERE id = NEW.reviewer_id;
  IF COALESCE(reviewer_role, '') NOT IN ('hr_manager', 'superadmin') THEN
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


--
-- Name: enforce_test_score_author(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_test_score_author() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
  IF COALESCE(author_role, '') NOT IN ('hr_manager', 'superadmin') OR (job_consultant IS NOT NULL AND job_consultant = NEW.entered_by_id) THEN
    RAISE EXCEPTION 'score_entries: a technical test answer is scored by a reviewer who is not the job''s consultant'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: enforce_user_recommendation_actor(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_user_recommendation_actor() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF COALESCE((SELECT role FROM users WHERE id = NEW.entered_by_id), '') NOT IN ('hr_admin', 'superadmin') THEN
    RAISE EXCEPTION 'user recommendation refused: only the HR PIC enters it (D62 h6)'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT user_in_job_company(NEW.entered_by_id, (SELECT job_id FROM job_applications WHERE id = NEW.job_application_id)) THEN
    RAISE EXCEPTION 'user recommendation refused: the HR PIC belongs to another company' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: forbid_score_after_gate_elimination(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forbid_score_after_gate_elimination() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM decisions d WHERE d.participation_id = NEW.participation_id
               AND d.reason_code = 'gate_eliminated'
               AND NOT EXISTS (SELECT 1 FROM decisions later WHERE later.supersedes_id = d.id)) THEN
    RAISE EXCEPTION 'score_entries: this test is closed by the gate (S1 eliminated); it is never scored'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: forbid_truncate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forbid_truncate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: TRUNCATE refused', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: forbid_update_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forbid_update_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: reopen_test_after_s1_correction(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reopen_test_after_s1_correction() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE s1 stages%ROWTYPE; p2 bigint; gate_row decisions%ROWTYPE;
BEGIN
  IF NEW.outcome = 'eliminate' OR NEW.supersedes_id IS NULL THEN RETURN NULL; END IF;
  SELECT st.* INTO s1 FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
  IF s1.gate IS NULL OR s1.code <> 'S1' OR s1.status <> 'closed' THEN RETURN NULL; END IF;
  SELECT p.id INTO p2 FROM participations p
    JOIN stages st ON st.id = p.stage_id AND st.job_id = s1.job_id AND st.gate = s1.gate AND st.code = 'S2'
    WHERE p.job_application_id = (SELECT job_application_id FROM participations WHERE id = NEW.participation_id);
  IF p2 IS NULL THEN RETURN NULL; END IF;
  SELECT d.* INTO gate_row FROM decisions d
    WHERE d.participation_id = p2 AND NOT EXISTS (SELECT 1 FROM decisions later WHERE later.supersedes_id = d.id);
  IF NOT FOUND OR gate_row.reason_code <> 'gate_eliminated' THEN RETURN NULL; END IF;
  INSERT INTO decisions (participation_id, outcome, basis, reason_code, note, decided_by_id, decided_at, supersedes_id)
  VALUES (p2, 'review', 'manual', 'gate_reopened_after_s1_correction',
          'Dinilai ulang setelah keputusan Seleksi CV dikoreksi; tes teknis perlu dijadwalkan untuk pelamar ini.',
          NEW.decided_by_id, NEW.decided_at, gate_row.id);
  RETURN NULL;
END;
$$;


--
-- Name: screening_judgements_without_quotes(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.screening_judgements_without_quotes(j jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(e) = 'object' THEN e || '{"quote": null}'::jsonb ELSE e END ORDER BY o), '[]'::jsonb)
      FROM jsonb_array_elements(j) WITH ORDINALITY AS t(e, o)
  $$;


--
-- Name: screening_result_erasures_result_exists(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.screening_result_erasures_result_exists() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM screening_results WHERE id = NEW.screening_result_id) THEN
    RAISE EXCEPTION 'screening_result_erasures: screening result % does not exist', NEW.screening_result_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: screening_results_erase_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.screening_results_erase_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  target jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'screening_results is append-only: DELETE refused' USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM screening_result_erasures WHERE screening_result_id = OLD.id) THEN
    RAISE EXCEPTION 'screening_results is append-only: UPDATE refused (no screening_result_erasures row for %)', OLD.id
      USING ERRCODE = 'restrict_violation';
  END IF;
  target := to_jsonb(OLD)
    || jsonb_build_object('last_position', NULL, 'education', NULL, 'recent_experience', NULL,
                          'narratives', NULL, 'label_reason', NULL,
                          'judgements', screening_judgements_without_quotes(OLD.judgements));
  IF to_jsonb(NEW) IS DISTINCT FROM target THEN
    RAISE EXCEPTION 'screening_results is append-only: UPDATE refused (only erasing the quote and report text fields, all at once, is allowed)'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: stage_text_erase_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stage_text_erase_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: test_case_is_final(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.test_case_is_final(case_id bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT EXISTS (SELECT 1 FROM test_attempts a WHERE a.test_case_id = case_id)
      OR EXISTS (SELECT 1 FROM test_cases c WHERE c.id = case_id AND c.approved_at IS NOT NULL);
$$;


--
-- Name: user_in_job_company(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_in_job_company(user_id bigint, job_id bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT u.client_company_id IS NULL OR u.client_company_id = j.client_company_id
  FROM users u, jobs j WHERE u.id = user_id AND j.id = job_id
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    service_name character varying NOT NULL,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activities (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    "position" integer NOT NULL,
    description text NOT NULL,
    output text NOT NULL,
    share_percent integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT activities_share_0_to_100 CHECK (((share_percent >= 0) AND (share_percent <= 100)))
);


--
-- Name: activities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activities_id_seq OWNED BY public.activities.id;


--
-- Name: ai_release_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_release_actions (
    id bigint NOT NULL,
    ai_release_id bigint NOT NULL,
    action character varying NOT NULL,
    actor_id bigint NOT NULL,
    payload_sha256 character varying,
    checked boolean DEFAULT false NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ai_release_actions_action CHECK (((action)::text = ANY (ARRAY[('released'::character varying)::text, ('declined'::character varying)::text]))),
    CONSTRAINT ai_release_actions_decline_has_note CHECK ((((action)::text <> 'declined'::text) OR (length(btrim(COALESCE(note, ''::text))) > 0))),
    CONSTRAINT ai_release_actions_release_checked CHECK ((((action)::text <> 'released'::text) OR (checked AND (payload_sha256 IS NOT NULL))))
);


--
-- Name: ai_release_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_release_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_release_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_release_actions_id_seq OWNED BY public.ai_release_actions.id;


--
-- Name: ai_release_erasures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_release_erasures (
    id bigint NOT NULL,
    ai_release_id bigint NOT NULL,
    actor_id bigint,
    reason character varying NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ai_release_erasures_reason CHECK (((reason)::text = ANY (ARRAY[('retention_expired'::character varying)::text, ('consent_withdrawn'::character varying)::text, ('no_consent'::character varying)::text])))
);


--
-- Name: ai_release_erasures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_release_erasures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_release_erasures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_release_erasures_id_seq OWNED BY public.ai_release_erasures.id;


--
-- Name: ai_releases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_releases (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    job_id bigint NOT NULL,
    payload_kind character varying NOT NULL,
    payload_text text,
    payload_sha256 character varying NOT NULL,
    cv_line_start integer NOT NULL,
    cv_line_end integer NOT NULL,
    rubric_digest character varying NOT NULL,
    source_sha256 character varying NOT NULL,
    residual_categories character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    supersedes_id bigint,
    cut_by_id bigint,
    cut_line_numbers integer[] DEFAULT '{}'::integer[] NOT NULL,
    cut_sha256 character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT ai_releases_cut_complete CHECK ((((supersedes_id IS NULL) = (cut_by_id IS NULL)) AND ((supersedes_id IS NULL) = (cut_sha256 IS NULL)) AND ((supersedes_id IS NULL) OR (cardinality(cut_line_numbers) > 0)))),
    CONSTRAINT ai_releases_cv_lines CHECK (((cv_line_start >= 0) AND (cv_line_end >= (cv_line_start - 1)))),
    CONSTRAINT ai_releases_digest_matches_text CHECK (((payload_text IS NULL) OR ((payload_sha256)::text = encode(sha256(convert_to(payload_text, 'UTF8'::name)), 'hex'::text)))),
    CONSTRAINT ai_releases_payload_kind CHECK (((payload_kind)::text = ANY (ARRAY[('cv_screening'::character varying)::text, ('interview_note'::character varying)::text, ('stage_recommendation'::character varying)::text])))
);


--
-- Name: ai_releases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_releases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_releases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_releases_id_seq OWNED BY public.ai_releases.id;


--
-- Name: application_drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application_drafts (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    token_digest character varying NOT NULL,
    name character varying,
    email character varying,
    phone character varying,
    domicile_city character varying,
    expected_salary_min bigint,
    expected_salary_max bigint,
    knockout_answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    consent_template_id bigint NOT NULL,
    consent_retention_days integer NOT NULL,
    consent_at timestamp(6) without time zone NOT NULL,
    channel_code character varying,
    question_bank_id bigint NOT NULL,
    draw bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    time_limit_minutes integer NOT NULL,
    grace_seconds integer DEFAULT 120 NOT NULL,
    test_started_at timestamp(6) without time zone,
    test_due_at timestamp(6) without time zone,
    submitted_at timestamp(6) without time zone,
    job_application_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    ai_status character varying,
    ai_error text,
    CONSTRAINT application_drafts_ai_status CHECK (((ai_status IS NULL) OR ((ai_status)::text = ANY ((ARRAY['pending'::character varying, 'done'::character varying, 'failed'::character varying])::text[])))),
    CONSTRAINT application_drafts_due_from_limit CHECK (((test_started_at IS NULL) OR (test_due_at = (test_started_at + make_interval(mins => time_limit_minutes))))),
    CONSTRAINT application_drafts_grace_range CHECK (((grace_seconds >= 0) AND (grace_seconds <= 600))),
    CONSTRAINT application_drafts_started_has_draw CHECK (((test_started_at IS NULL) OR (cardinality(draw) >= 1))),
    CONSTRAINT application_drafts_submitted_has_application CHECK (((submitted_at IS NULL) = (job_application_id IS NULL))),
    CONSTRAINT application_drafts_test_pair CHECK (((test_started_at IS NULL) = (test_due_at IS NULL))),
    CONSTRAINT application_drafts_time_limit_range CHECK (((time_limit_minutes >= 1) AND (time_limit_minutes <= 60)))
);


--
-- Name: application_drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.application_drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: application_drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.application_drafts_id_seq OWNED BY public.application_drafts.id;


--
-- Name: application_window_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application_window_events (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    action character varying NOT NULL,
    closes_at timestamp(6) without time zone,
    quota integer,
    reason text,
    actor_id bigint NOT NULL,
    actor_role character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT window_events_action CHECK (((action)::text = ANY (ARRAY[('open'::character varying)::text, ('close'::character varying)::text, ('reopen'::character varying)::text]))),
    CONSTRAINT window_events_quota_positive CHECK (((quota IS NULL) OR (quota > 0))),
    CONSTRAINT window_events_reopen_reason CHECK ((((action)::text <> 'reopen'::text) OR (length(btrim(COALESCE(reason, ''::text))) > 0)))
);


--
-- Name: application_window_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.application_window_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: application_window_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.application_window_events_id_seq OWNED BY public.application_window_events.id;


--
-- Name: appointment_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_changes (
    id bigint NOT NULL,
    appointment_id bigint NOT NULL,
    old_starts_at timestamp(6) without time zone,
    new_starts_at timestamp(6) without time zone NOT NULL,
    actor_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: appointment_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.appointment_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: appointment_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.appointment_changes_id_seq OWNED BY public.appointment_changes.id;


--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    starts_at timestamp(6) without time zone NOT NULL,
    ends_at timestamp(6) without time zone NOT NULL,
    mode character varying NOT NULL,
    place_or_link character varying NOT NULL,
    bring character varying,
    contact character varying NOT NULL,
    confirmation character varying DEFAULT 'pending'::character varying NOT NULL,
    reschedule_reason text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    calendar_event_id character varying,
    calendar_status character varying,
    calendar_error character varying(500),
    calendar_synced_at timestamp(6) without time zone,
    CONSTRAINT appointments_calendar_status CHECK (((calendar_status IS NULL) OR ((calendar_status)::text = ANY (ARRAY[('synced'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text])))),
    CONSTRAINT appointments_confirmation CHECK (((confirmation)::text = ANY (ARRAY[('pending'::character varying)::text, ('confirmed'::character varying)::text, ('reschedule_requested'::character varying)::text]))),
    CONSTRAINT appointments_mode CHECK (((mode)::text = ANY (ARRAY[('onsite'::character varying)::text, ('video'::character varying)::text, ('phone'::character varying)::text]))),
    CONSTRAINT appointments_order CHECK ((ends_at > starts_at))
);


--
-- Name: appointments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.appointments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: appointments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.appointments_id_seq OWNED BY public.appointments.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: bank_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_questions (
    id bigint NOT NULL,
    question_bank_id bigint NOT NULL,
    section character varying NOT NULL,
    kind character varying NOT NULL,
    "position" integer NOT NULL,
    activity_id bigint,
    activity_text text,
    competency_id bigint,
    competency_name character varying,
    prompt text NOT NULL,
    options text[] DEFAULT '{}'::text[] NOT NULL,
    correct_index integer,
    anchor_1 text,
    anchor_3 text,
    anchor_5 text,
    source character varying DEFAULT 'manual'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT bank_questions_kind CHECK (((kind)::text = ANY (ARRAY[('multiple_choice'::character varying)::text, ('written'::character varying)::text]))),
    CONSTRAINT bank_questions_link_matches_section CHECK (((((section)::text = 'technical'::text) AND (competency_id IS NULL)) OR (((section)::text = 'role'::text) AND (activity_id IS NULL)))),
    CONSTRAINT bank_questions_position_positive CHECK (("position" >= 1)),
    CONSTRAINT bank_questions_prompt_present CHECK ((length(btrim(prompt)) > 0)),
    CONSTRAINT bank_questions_section CHECK (((section)::text = ANY (ARRAY[('technical'::character varying)::text, ('role'::character varying)::text]))),
    CONSTRAINT bank_questions_shape CHECK (((((kind)::text = 'multiple_choice'::text) AND ((cardinality(options) >= 2) AND (cardinality(options) <= 6)) AND (correct_index IS NOT NULL) AND (correct_index >= 0) AND (correct_index < cardinality(options))) OR (((kind)::text = 'written'::text) AND (cardinality(options) = 0) AND (correct_index IS NULL)))),
    CONSTRAINT bank_questions_source CHECK (((source)::text = ANY (ARRAY[('manual'::character varying)::text, ('ai'::character varying)::text, ('import'::character varying)::text])))
);


--
-- Name: bank_questions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bank_questions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bank_questions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bank_questions_id_seq OWNED BY public.bank_questions.id;


--
-- Name: brief_suggestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brief_suggestions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    actor_id bigint NOT NULL,
    model_id character varying NOT NULL,
    prompt_version character varying NOT NULL,
    payload jsonb NOT NULL,
    input_tokens integer,
    output_tokens integer,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: brief_suggestions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.brief_suggestions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: brief_suggestions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.brief_suggestions_id_seq OWNED BY public.brief_suggestions.id;


--
-- Name: calibration_judgements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calibration_judgements (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    participation_id bigint NOT NULL,
    rubric_digest character varying NOT NULL,
    outcome character varying NOT NULL,
    note text,
    judged_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT calibration_judgements_outcome CHECK (((outcome)::text = ANY (ARRAY[('pass'::character varying)::text, ('eliminate'::character varying)::text])))
);


--
-- Name: calibration_judgements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calibration_judgements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calibration_judgements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calibration_judgements_id_seq OWNED BY public.calibration_judgements.id;


--
-- Name: candidate_letters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.candidate_letters (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    kind character varying NOT NULL,
    status character varying NOT NULL,
    subject character varying NOT NULL,
    body text NOT NULL,
    mail_delivery_id bigint,
    actor_id bigint NOT NULL,
    model_id character varying,
    prompt_version character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT candidate_letters_kind CHECK (((kind)::text = ANY (ARRAY[('rejection'::character varying)::text, ('offer'::character varying)::text]))),
    CONSTRAINT candidate_letters_sent_has_delivery CHECK ((((status)::text = 'draft'::text) OR (mail_delivery_id IS NOT NULL))),
    CONSTRAINT candidate_letters_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('sent'::character varying)::text])))
);


--
-- Name: candidate_letters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.candidate_letters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: candidate_letters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.candidate_letters_id_seq OWNED BY public.candidate_letters.id;


--
-- Name: candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.candidates (
    id bigint NOT NULL,
    name character varying NOT NULL,
    email character varying NOT NULL,
    phone character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: candidates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.candidates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: candidates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.candidates_id_seq OWNED BY public.candidates.id;


--
-- Name: client_companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_companies (
    id bigint NOT NULL,
    name character varying NOT NULL,
    address character varying NOT NULL,
    city character varying NOT NULL,
    contact_email character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: client_companies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_companies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_companies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_companies_id_seq OWNED BY public.client_companies.id;


--
-- Name: competencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.competencies (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    "position" integer NOT NULL,
    name character varying NOT NULL,
    layer character varying NOT NULL,
    stage_code character varying NOT NULL,
    anchor_1 text,
    anchor_3 text,
    anchor_5 text,
    questions text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT competencies_layer CHECK (((layer)::text = ANY (ARRAY[('L1'::character varying)::text, ('L2'::character varying)::text, ('L3'::character varying)::text, ('L4'::character varying)::text, ('L5'::character varying)::text, ('I'::character varying)::text]))),
    CONSTRAINT competencies_stage_code CHECK (((stage_code)::text = ANY (ARRAY[('S1'::character varying)::text, ('S2'::character varying)::text, ('S3'::character varying)::text, ('S4'::character varying)::text, ('S5'::character varying)::text])))
);


--
-- Name: competencies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.competencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: competencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.competencies_id_seq OWNED BY public.competencies.id;


--
-- Name: consent_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consent_templates (
    id bigint NOT NULL,
    version character varying NOT NULL,
    controller_identity text NOT NULL,
    legal_basis text NOT NULL,
    purpose text NOT NULL,
    data_types text NOT NULL,
    collected_items text NOT NULL,
    processing_duration text NOT NULL,
    rights text NOT NULL,
    effective_from timestamp(6) without time zone NOT NULL,
    created_by_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    client_company_id bigint,
    CONSTRAINT consent_templates_purpose_present CHECK ((length(btrim(purpose)) > 0))
);


--
-- Name: consent_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consent_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consent_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consent_templates_id_seq OWNED BY public.consent_templates.id;


--
-- Name: data_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_questions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    question text NOT NULL,
    status character varying NOT NULL,
    tool character varying,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    answer text,
    model_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    data jsonb,
    CONSTRAINT data_questions_status CHECK (((status)::text = ANY (ARRAY[('answered'::character varying)::text, ('refused'::character varying)::text, ('out_of_scope'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: data_questions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.data_questions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_questions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.data_questions_id_seq OWNED BY public.data_questions.id;


--
-- Name: decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.decisions (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    outcome character varying NOT NULL,
    basis character varying NOT NULL,
    reason_code character varying NOT NULL,
    note text,
    decided_by_id bigint,
    decided_at timestamp(6) without time zone NOT NULL,
    supersedes_id bigint,
    CONSTRAINT decisions_basis CHECK (((basis)::text = ANY (ARRAY[('threshold'::character varying)::text, ('manual'::character varying)::text, ('rule'::character varying)::text]))),
    CONSTRAINT decisions_gate_eliminated_is_rule CHECK ((((reason_code)::text <> 'gate_eliminated'::text) OR (((basis)::text = 'rule'::text) AND ((outcome)::text = 'eliminate'::text)))),
    CONSTRAINT decisions_manual_has_reason_and_actor CHECK ((((basis)::text <> 'manual'::text) OR ((length(btrim(COALESCE(note, ''::text))) > 0) AND (decided_by_id IS NOT NULL)))),
    CONSTRAINT decisions_outcome CHECK (((outcome)::text = ANY (ARRAY[('pass'::character varying)::text, ('eliminate'::character varying)::text, ('review'::character varying)::text])))
);


--
-- Name: decisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.decisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.decisions_id_seq OWNED BY public.decisions.id;


--
-- Name: draft_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.draft_answers (
    id bigint NOT NULL,
    application_draft_id bigint NOT NULL,
    bank_question_id bigint NOT NULL,
    choice_index integer,
    answer_text text,
    correct boolean,
    saved_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    ai_rating integer,
    ai_quote text,
    ai_reason text,
    ai_quote_verified boolean,
    ai_model character varying,
    ai_prompt_version character varying,
    ai_rated_at timestamp(6) without time zone,
    review_rating integer,
    reviewed_by_id bigint,
    reviewed_at timestamp(6) without time zone,
    CONSTRAINT draft_answers_ai_rating_range CHECK (((ai_rating IS NULL) OR ((ai_rating >= 1) AND (ai_rating <= 5)))),
    CONSTRAINT draft_answers_choice_range CHECK (((choice_index IS NULL) OR ((choice_index >= 0) AND (choice_index <= 5)))),
    CONSTRAINT draft_answers_one_kind CHECK (((choice_index IS NULL) OR (answer_text IS NULL))),
    CONSTRAINT draft_answers_review_complete CHECK ((((review_rating IS NULL) = (reviewed_by_id IS NULL)) AND ((reviewed_by_id IS NULL) = (reviewed_at IS NULL)))),
    CONSTRAINT draft_answers_review_rating_range CHECK (((review_rating IS NULL) OR ((review_rating >= 1) AND (review_rating <= 5))))
);


--
-- Name: draft_answers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.draft_answers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: draft_answers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.draft_answers_id_seq OWNED BY public.draft_answers.id;


--
-- Name: google_integration_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.google_integration_events (
    id bigint NOT NULL,
    integration character varying NOT NULL,
    outcome character varying NOT NULL,
    source character varying NOT NULL,
    error_class character varying,
    message character varying(500),
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT google_integration_events_integration CHECK (((integration)::text = ANY (ARRAY[('login'::character varying)::text, ('mail'::character varying)::text, ('storage'::character varying)::text, ('calendar'::character varying)::text]))),
    CONSTRAINT google_integration_events_outcome CHECK (((outcome)::text = ANY (ARRAY[('ok'::character varying)::text, ('failed'::character varying)::text]))),
    CONSTRAINT google_integration_events_source CHECK (((source)::text = ANY (ARRAY[('check'::character varying)::text, ('sync'::character varying)::text, ('login'::character varying)::text])))
);


--
-- Name: google_integration_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.google_integration_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: google_integration_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.google_integration_events_id_seq OWNED BY public.google_integration_events.id;


--
-- Name: interviewer_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interviewer_invites (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    interviewer_name character varying NOT NULL,
    issued_by_id bigint NOT NULL,
    score_entry_id bigint,
    submitted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT interviewer_invites_named CHECK ((length(btrim((interviewer_name)::text)) > 0)),
    CONSTRAINT interviewer_invites_submitted_has_score CHECK (((submitted_at IS NULL) = (score_entry_id IS NULL)))
);


--
-- Name: interviewer_invites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.interviewer_invites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: interviewer_invites_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.interviewer_invites_id_seq OWNED BY public.interviewer_invites.id;


--
-- Name: job_applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_applications (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    candidate_id bigint,
    channel_code character varying,
    knockout_answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    consent_at timestamp(6) without time zone,
    consent_template_id bigint,
    consent_retention_days integer,
    consent_withdrawn_at timestamp(6) without time zone,
    cv_text text,
    cv_text_source character varying,
    cv_text_at timestamp(6) without time zone,
    cv_text_by_id bigint,
    expected_salary_min bigint,
    expected_salary_max bigint,
    domicile_city character varying(60),
    CONSTRAINT job_applications_consent_recorded CHECK (((candidate_id IS NULL) OR ((consent_at IS NOT NULL) AND (consent_template_id IS NOT NULL) AND (consent_retention_days IS NOT NULL) AND (consent_retention_days > 0)))),
    CONSTRAINT job_applications_cv_text_source CHECK (((cv_text_source IS NULL) OR ((cv_text_source)::text = ANY (ARRAY[('pdf'::character varying)::text, ('pasted'::character varying)::text])))),
    CONSTRAINT job_applications_domicile_city_shape CHECK (((domicile_city IS NULL) OR ((length(btrim((domicile_city)::text)) >= 1) AND (length(btrim((domicile_city)::text)) <= 60) AND ((domicile_city)::text !~ '[0-9]'::text)))),
    CONSTRAINT job_applications_expected_salary CHECK ((((expected_salary_min IS NULL) AND (expected_salary_max IS NULL)) OR ((expected_salary_min IS NOT NULL) AND (expected_salary_max IS NOT NULL) AND (expected_salary_min > 0) AND (expected_salary_max >= expected_salary_min)))),
    CONSTRAINT job_applications_pasted_cv_has_actor CHECK ((((cv_text_source)::text <> 'pasted'::text) OR (cv_text_by_id IS NOT NULL)))
);


--
-- Name: job_applications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.job_applications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: job_applications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.job_applications_id_seq OWNED BY public.job_applications.id;


--
-- Name: job_brief_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_brief_changes (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    actor_id bigint NOT NULL,
    actor_role character varying NOT NULL,
    step character varying NOT NULL,
    changes_made jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: job_brief_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.job_brief_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: job_brief_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.job_brief_changes_id_seq OWNED BY public.job_brief_changes.id;


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id bigint NOT NULL,
    title character varying NOT NULL,
    golongan integer NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    client_company_id bigint NOT NULL,
    public_code character varying,
    location character varying,
    salary_min bigint,
    salary_max bigint,
    show_salary boolean DEFAULT false NOT NULL,
    confidential boolean DEFAULT false NOT NULL,
    ad_approved_at timestamp(6) without time zone,
    ad_approved_by_id bigint,
    headcount integer,
    employment_type character varying,
    work_arrangement character varying,
    placements character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    relocation character varying,
    success_90d text,
    package integer,
    package_override_reason text,
    stage_plan jsonb DEFAULT '{}'::jsonb NOT NULL,
    brief_status character varying DEFAULT 'draft'::character varying NOT NULL,
    brief_completed_at timestamp(6) without time zone,
    consultant_id bigint,
    screening_sample_seed character varying,
    ad_text text,
    ad_flags jsonb DEFAULT '[]'::jsonb NOT NULL,
    requirement_check jsonb DEFAULT '{}'::jsonb NOT NULL,
    ai_model_tiers jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT jobs_brief_status CHECK (((brief_status)::text = ANY (ARRAY[('draft'::character varying)::text, ('complete'::character varying)::text]))),
    CONSTRAINT jobs_employment_type CHECK (((employment_type IS NULL) OR ((employment_type)::text = ANY (ARRAY[('tetap_pkwtt'::character varying)::text, ('kontrak_pkwt'::character varying)::text, ('harian_lepas'::character varying)::text, ('magang'::character varying)::text])))),
    CONSTRAINT jobs_golongan_1_to_8 CHECK (((golongan >= 1) AND (golongan <= 8))),
    CONSTRAINT jobs_headcount_positive CHECK (((headcount IS NULL) OR (headcount > 0))),
    CONSTRAINT jobs_package_1_to_5 CHECK (((package IS NULL) OR ((package >= 1) AND (package <= 5)))),
    CONSTRAINT jobs_relocation CHECK (((relocation IS NULL) OR ((relocation)::text = ANY (ARRAY[('wajib'::character varying)::text, ('diutamakan'::character varying)::text, ('tidak_perlu'::character varying)::text])))),
    CONSTRAINT jobs_salary_band_order CHECK (((salary_min IS NULL) OR (salary_max IS NULL) OR (salary_min <= salary_max))),
    CONSTRAINT jobs_work_arrangement CHECK (((work_arrangement IS NULL) OR ((work_arrangement)::text = ANY (ARRAY[('onsite'::character varying)::text, ('hybrid'::character varying)::text, ('remote'::character varying)::text]))))
);


--
-- Name: jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.jobs_id_seq OWNED BY public.jobs.id;


--
-- Name: knockout_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knockout_questions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    "position" integer NOT NULL,
    text character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    requirement_id bigint
);


--
-- Name: knockout_questions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knockout_questions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knockout_questions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knockout_questions_id_seq OWNED BY public.knockout_questions.id;


--
-- Name: link_opens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.link_opens (
    id bigint NOT NULL,
    one_time_link_id bigint NOT NULL,
    opened_at timestamp(6) without time zone NOT NULL
);


--
-- Name: link_opens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.link_opens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: link_opens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.link_opens_id_seq OWNED BY public.link_opens.id;


--
-- Name: link_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.link_requests (
    id bigint NOT NULL,
    job_application_id bigint,
    job_code character varying,
    contact character varying NOT NULL,
    handled_at timestamp(6) without time zone,
    handled_by_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    job_id bigint
);


--
-- Name: link_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.link_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: link_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.link_requests_id_seq OWNED BY public.link_requests.id;


--
-- Name: mail_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mail_deliveries (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    kind character varying NOT NULL,
    status character varying NOT NULL,
    error_class character varying,
    error_message text,
    handled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    handled_by_id bigint,
    CONSTRAINT mail_deliveries_status CHECK (((status)::text = ANY (ARRAY[('sent'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: mail_deliveries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mail_deliveries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mail_deliveries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mail_deliveries_id_seq OWNED BY public.mail_deliveries.id;


--
-- Name: objections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.objections (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    text text NOT NULL,
    received_at timestamp(6) without time zone NOT NULL,
    answered_by_id bigint,
    outcome character varying,
    answer text,
    answered_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT objections_outcome CHECK (((outcome IS NULL) OR ((outcome)::text = ANY (ARRAY[('upheld'::character varying)::text, ('not_upheld'::character varying)::text]))))
);


--
-- Name: objections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.objections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: objections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.objections_id_seq OWNED BY public.objections.id;


--
-- Name: offer_access_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_access_codes (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    code_digest character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    used_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: offer_access_codes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.offer_access_codes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: offer_access_codes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.offer_access_codes_id_seq OWNED BY public.offer_access_codes.id;


--
-- Name: offer_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_documents (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    version integer NOT NULL,
    start_at timestamp(6) without time zone NOT NULL,
    valid_until date NOT NULL,
    day_one_notes text NOT NULL,
    uploaded_by_id bigint NOT NULL,
    response character varying,
    response_reason text,
    responded_at timestamp(6) without time zone,
    followed_up_at timestamp(6) without time zone,
    followed_up_by_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT offer_documents_decline_reason CHECK ((((response)::text IS DISTINCT FROM 'declined'::text) OR (length(btrim(COALESCE(response_reason, ''::text))) > 0))),
    CONSTRAINT offer_documents_response CHECK (((response IS NULL) OR ((response)::text = ANY (ARRAY[('accepted'::character varying)::text, ('declined'::character varying)::text]))))
);


--
-- Name: offer_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.offer_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: offer_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.offer_documents_id_seq OWNED BY public.offer_documents.id;


--
-- Name: one_time_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.one_time_links (
    id bigint NOT NULL,
    token_digest character varying NOT NULL,
    purpose character varying NOT NULL,
    subject_type character varying NOT NULL,
    subject_id bigint NOT NULL,
    expires_at timestamp(6) without time zone,
    used_at timestamp(6) without time zone,
    revoked_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: one_time_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.one_time_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: one_time_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.one_time_links_id_seq OWNED BY public.one_time_links.id;


--
-- Name: participations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.participations (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    stage_id bigint NOT NULL,
    attendance character varying DEFAULT 'pending'::character varying NOT NULL,
    scheduled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    screening_state character varying,
    screening_failure character varying,
    screening_failure_detail character varying,
    screening_state_at timestamp(6) without time zone,
    CONSTRAINT participations_attendance CHECK (((attendance)::text = ANY (ARRAY[('pending'::character varying)::text, ('attended'::character varying)::text, ('no_show'::character varying)::text, ('withdrew'::character varying)::text]))),
    CONSTRAINT participations_screening_state CHECK (((screening_state IS NULL) OR ((screening_state)::text = ANY (ARRAY[('queued'::character varying)::text, ('done'::character varying)::text, ('screening_failed'::character varying)::text, ('cv_unreadable'::character varying)::text, ('awaiting_release'::character varying)::text, ('not_sent'::character varying)::text]))))
);


--
-- Name: participations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.participations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: participations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.participations_id_seq OWNED BY public.participations.id;


--
-- Name: progression_choices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.progression_choices (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    stage_recommendation_id bigint,
    choice character varying NOT NULL,
    direction character varying NOT NULL,
    note text,
    actor_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT progression_choices_ai_names_recommendation CHECK ((((choice)::text <> 'ikut_ai'::text) OR (stage_recommendation_id IS NOT NULL))),
    CONSTRAINT progression_choices_choice CHECK (((choice)::text = ANY (ARRAY[('lanjut'::character varying)::text, ('ikut_ai'::character varying)::text, ('tidak_lanjut'::character varying)::text]))),
    CONSTRAINT progression_choices_direction CHECK (((direction)::text = ANY (ARRAY[('lanjut'::character varying)::text, ('tidak_lanjut'::character varying)::text]))),
    CONSTRAINT progression_choices_direction_matches CHECK ((((choice)::text = 'ikut_ai'::text) OR ((choice)::text = (direction)::text))),
    CONSTRAINT progression_choices_tidak_lanjut_has_note CHECK ((((direction)::text = 'lanjut'::text) OR (length(btrim(COALESCE(note, ''::text))) > 0)))
);


--
-- Name: progression_choices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.progression_choices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: progression_choices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.progression_choices_id_seq OWNED BY public.progression_choices.id;


--
-- Name: question_banks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_banks (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    version integer NOT NULL,
    technical_draw integer DEFAULT 5 NOT NULL,
    role_draw integer DEFAULT 3 NOT NULL,
    time_limit_minutes integer DEFAULT 30 NOT NULL,
    new_version_reason text,
    created_by_id bigint NOT NULL,
    submitted_by_id bigint,
    submitted_at timestamp(6) without time zone,
    approved_by_id bigint,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT question_banks_approval_pair CHECK (((approved_at IS NULL) = (approved_by_id IS NULL))),
    CONSTRAINT question_banks_approved_was_submitted CHECK (((approved_at IS NULL) OR (submitted_at IS NOT NULL))),
    CONSTRAINT question_banks_draws_range CHECK (((technical_draw >= 1) AND (technical_draw <= 20) AND ((role_draw >= 1) AND (role_draw <= 20)))),
    CONSTRAINT question_banks_new_version_has_reason CHECK (((version = 1) OR (length(btrim(COALESCE(new_version_reason, ''::text))) > 0))),
    CONSTRAINT question_banks_submission_pair CHECK (((submitted_at IS NULL) = (submitted_by_id IS NULL))),
    CONSTRAINT question_banks_time_limit_range CHECK (((time_limit_minutes >= 1) AND (time_limit_minutes <= 60))),
    CONSTRAINT question_banks_version_positive CHECK ((version >= 1))
);


--
-- Name: question_banks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.question_banks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: question_banks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.question_banks_id_seq OWNED BY public.question_banks.id;


--
-- Name: requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.requirements (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    tier character varying NOT NULL,
    "position" integer NOT NULL,
    text text NOT NULL,
    cv_evidence text NOT NULL,
    weight integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT requirements_tier CHECK (((tier)::text = ANY (ARRAY[('wajib'::character varying)::text, ('sebaiknya'::character varying)::text, ('nilai_tambah'::character varying)::text]))),
    CONSTRAINT requirements_weight_only_sebaiknya CHECK (((weight IS NULL) OR (((tier)::text = 'sebaiknya'::text) AND ((weight >= 0) AND (weight <= 100)))))
);


--
-- Name: requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.requirements_id_seq OWNED BY public.requirements.id;


--
-- Name: salary_agreements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.salary_agreements (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    salary_recommendation_id bigint,
    agreed_amount bigint NOT NULL,
    outside_band boolean NOT NULL,
    note text,
    decided_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT salary_agreements_outside_band_has_note CHECK (((NOT outside_band) OR (length(btrim(COALESCE(note, ''::text))) > 0))),
    CONSTRAINT salary_agreements_positive CHECK ((agreed_amount > 0))
);


--
-- Name: salary_agreements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.salary_agreements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: salary_agreements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.salary_agreements_id_seq OWNED BY public.salary_agreements.id;


--
-- Name: salary_recommendations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.salary_recommendations (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    status character varying NOT NULL,
    "position" numeric(4,3),
    amount bigint,
    summary text,
    factors jsonb DEFAULT '[]'::jsonb NOT NULL,
    problem text,
    model_id character varying,
    prompt_version character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT salary_recommendations_ready_complete CHECK ((((status)::text = 'ready'::text) = (("position" >= (0)::numeric) AND ("position" <= (1)::numeric) AND (amount > 0) AND (model_id IS NOT NULL)))),
    CONSTRAINT salary_recommendations_status CHECK (((status)::text = ANY (ARRAY[('ready'::character varying)::text, ('failed'::character varying)::text])))
);


--
-- Name: salary_recommendations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.salary_recommendations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: salary_recommendations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.salary_recommendations_id_seq OWNED BY public.salary_recommendations.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: score_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.score_entries (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    value numeric(4,1) NOT NULL,
    ratings jsonb DEFAULT '{}'::jsonb NOT NULL,
    entered_by_id bigint NOT NULL,
    event_at timestamp(6) without time zone,
    entered_at timestamp(6) without time zone NOT NULL,
    supersedes_id bigint,
    correction_reason text,
    model_id character varying,
    prompt_version character varying,
    note text,
    CONSTRAINT score_entries_ai_actor_names_model CHECK (((entered_by_id <> 0) OR (model_id IS NOT NULL))),
    CONSTRAINT score_entries_ai_trace_complete CHECK (((model_id IS NULL) = (prompt_version IS NULL))),
    CONSTRAINT score_entries_correction_has_reason CHECK (((supersedes_id IS NULL) OR (correction_reason IS NOT NULL))),
    CONSTRAINT score_entries_value_range CHECK (((value >= (0)::numeric) AND (value <= (100)::numeric)))
);


--
-- Name: score_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.score_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: score_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.score_entries_id_seq OWNED BY public.score_entries.id;


--
-- Name: screening_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_attempts (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    attempt integer NOT NULL,
    outcome character varying NOT NULL,
    error_kind character varying,
    detail character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT screening_attempts_outcome CHECK (((outcome)::text = ANY (ARRAY[('succeeded'::character varying)::text, ('failed'::character varying)::text, ('cv_unreadable'::character varying)::text])))
);


--
-- Name: screening_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_attempts_id_seq OWNED BY public.screening_attempts.id;


--
-- Name: screening_label_confirmations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_label_confirmations (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    screening_result_id bigint NOT NULL,
    reviewer_id bigint NOT NULL,
    label character varying NOT NULL,
    last_role_golongan integer,
    job_golongan integer NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT label_confirmations_golongan_range CHECK (((last_role_golongan IS NULL) OR ((last_role_golongan >= 1) AND (last_role_golongan <= 8)))),
    CONSTRAINT label_confirmations_label CHECK (((label)::text = ANY (ARRAY[('direkomendasikan'::character varying)::text, ('pertimbangkan'::character varying)::text, ('pertimbangkan_terbatas'::character varying)::text, ('over_qualified'::character varying)::text, ('tidak_prioritas'::character varying)::text, ('tidak_relevan'::character varying)::text]))),
    CONSTRAINT label_confirmations_over_qualified_rule CHECK ((((label)::text <> 'over_qualified'::text) OR ((length(btrim(COALESCE(note, ''::text))) > 0) AND (last_role_golongan IS NOT NULL) AND ((last_role_golongan - job_golongan) >= 2))))
);


--
-- Name: screening_label_confirmations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_label_confirmations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_label_confirmations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_label_confirmations_id_seq OWNED BY public.screening_label_confirmations.id;


--
-- Name: screening_narrative_approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_narrative_approvals (
    id bigint NOT NULL,
    screening_result_id bigint NOT NULL,
    approved_by_id bigint NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: screening_narrative_approvals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_narrative_approvals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_narrative_approvals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_narrative_approvals_id_seq OWNED BY public.screening_narrative_approvals.id;


--
-- Name: screening_result_erasures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_result_erasures (
    id bigint NOT NULL,
    screening_result_id bigint NOT NULL,
    actor_id bigint,
    reason character varying NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT screening_result_erasures_reason CHECK (((reason)::text = ANY (ARRAY[('retention_expired'::character varying)::text, ('consent_withdrawn'::character varying)::text, ('no_consent'::character varying)::text])))
);


--
-- Name: screening_result_erasures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_result_erasures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_result_erasures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_result_erasures_id_seq OWNED BY public.screening_result_erasures.id;


--
-- Name: screening_results; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_results (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    score_entry_id bigint,
    rubric_digest character varying NOT NULL,
    model_id character varying NOT NULL,
    prompt_version character varying NOT NULL,
    judgements jsonb NOT NULL,
    score numeric(4,1) NOT NULL,
    wajib_met boolean NOT NULL,
    unverified_count integer NOT NULL,
    bonus_points integer DEFAULT 0 NOT NULL,
    bonus_possible integer DEFAULT 0 NOT NULL,
    pass_ordinal integer,
    sampled boolean DEFAULT false NOT NULL,
    input_tokens integer,
    output_tokens integer,
    created_at timestamp(6) without time zone NOT NULL,
    protected_attribute_categories character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    last_position jsonb,
    education jsonb,
    recent_experience jsonb,
    narratives jsonb,
    label_proposal character varying,
    label_reason text,
    ai_release_id bigint,
    CONSTRAINT screening_results_label_proposal CHECK (((label_proposal IS NULL) OR ((label_proposal)::text = ANY (ARRAY[('direkomendasikan'::character varying)::text, ('pertimbangkan'::character varying)::text, ('pertimbangkan_terbatas'::character varying)::text, ('tidak_prioritas'::character varying)::text, ('tidak_relevan'::character varying)::text])))),
    CONSTRAINT screening_results_score_range CHECK (((score >= (0)::numeric) AND (score <= (100)::numeric)))
);


--
-- Name: screening_results_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_results_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_results_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_results_id_seq OWNED BY public.screening_results.id;


--
-- Name: screening_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screening_reviews (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    screening_result_id bigint NOT NULL,
    reviewer_id bigint NOT NULL,
    verdict character varying NOT NULL,
    reason character varying NOT NULL,
    note text,
    decision_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT screening_reviews_flagged_confirm_has_note CHECK ((((verdict)::text <> 'confirm'::text) OR ((reason)::text <> ALL (ARRAY[('unverified'::character varying)::text, ('protected_attribute'::character varying)::text])) OR (length(btrim(COALESCE(note, ''::text))) > 0))),
    CONSTRAINT screening_reviews_reason CHECK (((reason)::text = ANY (ARRAY[('elimination'::character varying)::text, ('sample'::character varying)::text, ('unverified'::character varying)::text, ('calibration_disagreement'::character varying)::text, ('protected_attribute'::character varying)::text]))),
    CONSTRAINT screening_reviews_reverse_has_note CHECK ((((verdict)::text <> 'reverse'::text) OR (length(btrim(COALESCE(note, ''::text))) > 0))),
    CONSTRAINT screening_reviews_verdict CHECK (((verdict)::text = ANY (ARRAY[('confirm'::character varying)::text, ('reverse'::character varying)::text])))
);


--
-- Name: screening_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.screening_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: screening_reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.screening_reviews_id_seq OWNED BY public.screening_reviews.id;


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: setting_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.setting_changes (
    id bigint NOT NULL,
    key character varying NOT NULL,
    old_value character varying,
    new_value character varying NOT NULL,
    actor_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    client_company_id bigint
);


--
-- Name: setting_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.setting_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: setting_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.setting_changes_id_seq OWNED BY public.setting_changes.id;


--
-- Name: sign_in_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sign_in_events (
    id bigint NOT NULL,
    user_id bigint,
    auth_method character varying NOT NULL,
    outcome character varying NOT NULL,
    reason character varying,
    email_domain character varying,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sign_in_events_auth_method CHECK (((auth_method)::text = ANY (ARRAY[('password'::character varying)::text, ('google'::character varying)::text, ('demo'::character varying)::text]))),
    CONSTRAINT sign_in_events_outcome CHECK (((outcome)::text = ANY (ARRAY[('success'::character varying)::text, ('refused'::character varying)::text]))),
    CONSTRAINT sign_in_events_success_has_user CHECK ((((outcome)::text <> 'success'::text) OR (user_id IS NOT NULL)))
);


--
-- Name: sign_in_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sign_in_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sign_in_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sign_in_events_id_seq OWNED BY public.sign_in_events.id;


--
-- Name: stage_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stage_changes (
    id bigint NOT NULL,
    stage_id bigint NOT NULL,
    field character varying NOT NULL,
    old_value numeric(4,1) NOT NULL,
    new_value numeric(4,1) NOT NULL,
    reason text NOT NULL,
    changed_by_id bigint NOT NULL,
    changed_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT stage_changes_field CHECK (((field)::text = ANY (ARRAY[('weight'::character varying)::text, ('threshold'::character varying)::text])))
);


--
-- Name: stage_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stage_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stage_changes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stage_changes_id_seq OWNED BY public.stage_changes.id;


--
-- Name: stage_recommendations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stage_recommendations (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    status character varying NOT NULL,
    advice character varying,
    ai_score numeric(4,1),
    summary text,
    reasons jsonb DEFAULT '{}'::jsonb NOT NULL,
    problem text,
    model_id character varying,
    prompt_version character varying NOT NULL,
    input_sha256 character varying,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT stage_recommendations_ready_has_advice CHECK ((((status)::text = 'ready'::text) = (((advice)::text = ANY (ARRAY[('lanjut'::character varying)::text, ('tidak_lanjut'::character varying)::text])) AND (model_id IS NOT NULL)))),
    CONSTRAINT stage_recommendations_score_range CHECK (((ai_score IS NULL) OR ((ai_score >= (0)::numeric) AND (ai_score <= (100)::numeric)))),
    CONSTRAINT stage_recommendations_status CHECK (((status)::text = ANY (ARRAY[('ready'::character varying)::text, ('failed'::character varying)::text, ('held'::character varying)::text])))
);


--
-- Name: stage_recommendations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stage_recommendations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stage_recommendations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stage_recommendations_id_seq OWNED BY public.stage_recommendations.id;


--
-- Name: stage_text_erasures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stage_text_erasures (
    id bigint NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    actor_id bigint,
    reason character varying NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT stage_text_erasures_reason CHECK (((reason)::text = ANY (ARRAY[('retention_expired'::character varying)::text, ('consent_withdrawn'::character varying)::text, ('no_consent'::character varying)::text]))),
    CONSTRAINT stage_text_erasures_record_type CHECK (((record_type)::text = ANY (ARRAY[('stage_recommendations'::character varying)::text, ('salary_recommendations'::character varying)::text, ('progression_choices'::character varying)::text, ('salary_agreements'::character varying)::text, ('score_entries'::character varying)::text])))
);


--
-- Name: stage_text_erasures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stage_text_erasures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stage_text_erasures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stage_text_erasures_id_seq OWNED BY public.stage_text_erasures.id;


--
-- Name: stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stages (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    code character varying NOT NULL,
    score_source character varying NOT NULL,
    weight integer NOT NULL,
    threshold numeric(4,1) NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    opened_at timestamp(6) without time zone,
    review_below_threshold boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    results_due_on date,
    gate character varying,
    CONSTRAINT stages_code CHECK (((code)::text = ANY (ARRAY[('S1'::character varying)::text, ('S2'::character varying)::text, ('S3'::character varying)::text, ('S4'::character varying)::text, ('S5'::character varying)::text, ('RC'::character varying)::text]))),
    CONSTRAINT stages_gate CHECK (((gate IS NULL) OR (((gate)::text = 'screening'::text) AND ((code)::text = ANY (ARRAY[('S1'::character varying)::text, ('S2'::character varying)::text]))))),
    CONSTRAINT stages_opened_at_when_open CHECK ((((status)::text = 'draft'::text) OR (opened_at IS NOT NULL))),
    CONSTRAINT stages_score_source CHECK (((score_source)::text = ANY (ARRAY[('ai'::character varying)::text, ('scorecard'::character varying)::text, ('manual_or_import'::character varying)::text, ('check'::character varying)::text]))),
    CONSTRAINT stages_status CHECK (((status)::text = ANY (ARRAY[('draft'::character varying)::text, ('open'::character varying)::text, ('closed'::character varying)::text]))),
    CONSTRAINT stages_threshold_range CHECK (((threshold >= (0)::numeric) AND (threshold <= (100)::numeric))),
    CONSTRAINT stages_weight_range CHECK (((weight >= 0) AND (weight <= 100)))
);


--
-- Name: stages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stages_id_seq OWNED BY public.stages.id;


--
-- Name: system_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_settings (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    client_company_id bigint
);


--
-- Name: system_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_settings_id_seq OWNED BY public.system_settings.id;


--
-- Name: test_ai_suggestions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_ai_suggestions (
    id bigint NOT NULL,
    test_attempt_id bigint NOT NULL,
    actor_id bigint NOT NULL,
    sent_sha256 character varying NOT NULL,
    model_id character varying NOT NULL,
    prompt_version character varying NOT NULL,
    payload jsonb NOT NULL,
    input_tokens integer,
    output_tokens integer,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: test_ai_suggestions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.test_ai_suggestions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_ai_suggestions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.test_ai_suggestions_id_seq OWNED BY public.test_ai_suggestions.id;


--
-- Name: test_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_attempts (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    test_case_id bigint NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    due_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    answered_at timestamp(6) without time zone,
    answer_blob_id bigint,
    answer_kind character varying,
    answer_sha256 character varying,
    answer_bytes bigint,
    answer_scan_state character varying,
    grace_seconds integer DEFAULT 120 NOT NULL,
    answer_url character varying,
    CONSTRAINT test_attempts_answer_complete CHECK (((num_nonnulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state, answer_url) = 0) OR (((answer_kind)::text <> 'repo_link'::text) AND (answer_url IS NULL) AND (num_nulls(answered_at, answer_blob_id, answer_kind, answer_sha256, answer_bytes, answer_scan_state) = 0)) OR (((answer_kind)::text = 'repo_link'::text) AND (answered_at IS NOT NULL) AND ((answer_url)::text ~ '^https://(github\.com|gitlab\.com|bitbucket\.org)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^[:space:]]*)?$'::text) AND (num_nonnulls(answer_blob_id, answer_sha256, answer_bytes, answer_scan_state) = 0)))),
    CONSTRAINT test_attempts_answer_in_time CHECK (((answered_at IS NULL) OR ((answered_at >= started_at) AND (answered_at <= (due_at + make_interval(secs => (grace_seconds)::double precision)))))),
    CONSTRAINT test_attempts_answer_kind CHECK (((answer_kind IS NULL) OR ((answer_kind)::text = ANY (ARRAY[('xlsx'::character varying)::text, ('docx'::character varying)::text, ('pdf'::character varying)::text, ('csv'::character varying)::text, ('repo_link'::character varying)::text])))),
    CONSTRAINT test_attempts_answer_max_10_mb CHECK (((answer_bytes IS NULL) OR ((answer_bytes >= 1) AND (answer_bytes <= 10485760)))),
    CONSTRAINT test_attempts_answer_scan_state CHECK (((answer_scan_state IS NULL) OR ((answer_scan_state)::text = ANY (ARRAY[('pending_scan'::character varying)::text, ('clean'::character varying)::text, ('scan_unavailable'::character varying)::text])))),
    CONSTRAINT test_attempts_due_after_start CHECK ((due_at > started_at)),
    CONSTRAINT test_attempts_grace_range CHECK (((grace_seconds >= 0) AND (grace_seconds <= 600)))
);


--
-- Name: test_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.test_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.test_attempts_id_seq OWNED BY public.test_attempts.id;


--
-- Name: test_case_criteria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_case_criteria (
    id bigint NOT NULL,
    test_case_id bigint NOT NULL,
    "position" integer NOT NULL,
    activity_id bigint,
    activity_text text NOT NULL,
    name text NOT NULL,
    weight integer NOT NULL,
    anchor_1 text NOT NULL,
    anchor_3 text NOT NULL,
    anchor_5 text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT test_case_criteria_weight CHECK (((weight >= 1) AND (weight <= 100)))
);


--
-- Name: test_case_criteria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.test_case_criteria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_case_criteria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.test_case_criteria_id_seq OWNED BY public.test_case_criteria.id;


--
-- Name: test_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_cases (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    version integer NOT NULL,
    instructions text DEFAULT ''::text NOT NULL,
    time_limit_minutes integer DEFAULT 35 NOT NULL,
    answer_types character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    new_version_reason text,
    case_file_blob_id bigint,
    case_file_kind character varying,
    case_file_sha256 character varying,
    case_file_bytes bigint,
    scan_state character varying,
    scanned_at timestamp(6) without time zone,
    created_by_id bigint NOT NULL,
    approved_by_id bigint,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT test_cases_answer_types CHECK ((answer_types <@ ARRAY['xlsx'::character varying, 'docx'::character varying, 'pdf'::character varying, 'csv'::character varying, 'repo_link'::character varying])),
    CONSTRAINT test_cases_approval_pair CHECK (((approved_at IS NULL) = (approved_by_id IS NULL))),
    CONSTRAINT test_cases_approved_is_complete CHECK (((approved_at IS NULL) OR ((case_file_blob_id IS NOT NULL) AND (scan_state IS NOT NULL) AND ((scan_state)::text <> 'infected'::text) AND (cardinality(answer_types) >= 1) AND (length(btrim(instructions)) > 0)))),
    CONSTRAINT test_cases_case_file_kind CHECK (((case_file_kind IS NULL) OR ((case_file_kind)::text = ANY (ARRAY[('xlsx'::character varying)::text, ('docx'::character varying)::text, ('pdf'::character varying)::text, ('csv'::character varying)::text])))),
    CONSTRAINT test_cases_case_file_max_20_mb CHECK (((case_file_bytes IS NULL) OR ((case_file_bytes >= 1) AND (case_file_bytes <= 20971520)))),
    CONSTRAINT test_cases_new_version_has_reason CHECK (((version = 1) OR (length(btrim(COALESCE(new_version_reason, ''::text))) > 0))),
    CONSTRAINT test_cases_scan_state CHECK (((scan_state IS NULL) OR ((scan_state)::text = ANY (ARRAY[('pending_scan'::character varying)::text, ('clean'::character varying)::text, ('infected'::character varying)::text, ('scan_unavailable'::character varying)::text])))),
    CONSTRAINT test_cases_time_limit_max_60 CHECK (((time_limit_minutes >= 1) AND (time_limit_minutes <= 60))),
    CONSTRAINT test_cases_version_positive CHECK ((version >= 1))
);


--
-- Name: test_cases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.test_cases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_cases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.test_cases_id_seq OWNED BY public.test_cases.id;


--
-- Name: test_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_reviews (
    id bigint NOT NULL,
    participation_id bigint NOT NULL,
    test_attempt_id bigint NOT NULL,
    reviewer_id bigint NOT NULL,
    score_entry_id bigint NOT NULL,
    decision_id bigint NOT NULL,
    ratings jsonb NOT NULL,
    note text,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: test_reviews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.test_reviews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_reviews_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.test_reviews_id_seq OWNED BY public.test_reviews.id;


--
-- Name: user_recommendations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_recommendations (
    id bigint NOT NULL,
    job_application_id bigint NOT NULL,
    user_name character varying NOT NULL,
    pick character varying NOT NULL,
    note text,
    entered_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT user_recommendations_pick CHECK (((pick)::text = ANY (ARRAY[('lanjut'::character varying)::text, ('tidak_lanjut'::character varying)::text]))),
    CONSTRAINT user_recommendations_user_named CHECK ((length(btrim((user_name)::text)) > 0))
);


--
-- Name: user_recommendations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_recommendations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_recommendations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_recommendations_id_seq OWNED BY public.user_recommendations.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying DEFAULT ''::character varying NOT NULL,
    role character varying DEFAULT 'hr_admin'::character varying NOT NULL,
    client_company_id bigint,
    CONSTRAINT users_client_roles_have_company CHECK ((((role)::text <> ALL (ARRAY[('hr_admin'::character varying)::text, ('hr_manager'::character varying)::text])) OR (client_company_id IS NOT NULL))),
    CONSTRAINT users_role CHECK (((role)::text = ANY (ARRAY[('superadmin'::character varying)::text, ('hr_admin'::character varying)::text, ('hr_manager'::character varying)::text])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: activities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities ALTER COLUMN id SET DEFAULT nextval('public.activities_id_seq'::regclass);


--
-- Name: ai_release_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_actions ALTER COLUMN id SET DEFAULT nextval('public.ai_release_actions_id_seq'::regclass);


--
-- Name: ai_release_erasures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_erasures ALTER COLUMN id SET DEFAULT nextval('public.ai_release_erasures_id_seq'::regclass);


--
-- Name: ai_releases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases ALTER COLUMN id SET DEFAULT nextval('public.ai_releases_id_seq'::regclass);


--
-- Name: application_drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts ALTER COLUMN id SET DEFAULT nextval('public.application_drafts_id_seq'::regclass);


--
-- Name: application_window_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_window_events ALTER COLUMN id SET DEFAULT nextval('public.application_window_events_id_seq'::regclass);


--
-- Name: appointment_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_changes ALTER COLUMN id SET DEFAULT nextval('public.appointment_changes_id_seq'::regclass);


--
-- Name: appointments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments ALTER COLUMN id SET DEFAULT nextval('public.appointments_id_seq'::regclass);


--
-- Name: bank_questions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_questions ALTER COLUMN id SET DEFAULT nextval('public.bank_questions_id_seq'::regclass);


--
-- Name: brief_suggestions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_suggestions ALTER COLUMN id SET DEFAULT nextval('public.brief_suggestions_id_seq'::regclass);


--
-- Name: calibration_judgements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judgements ALTER COLUMN id SET DEFAULT nextval('public.calibration_judgements_id_seq'::regclass);


--
-- Name: candidate_letters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidate_letters ALTER COLUMN id SET DEFAULT nextval('public.candidate_letters_id_seq'::regclass);


--
-- Name: candidates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidates ALTER COLUMN id SET DEFAULT nextval('public.candidates_id_seq'::regclass);


--
-- Name: client_companies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_companies ALTER COLUMN id SET DEFAULT nextval('public.client_companies_id_seq'::regclass);


--
-- Name: competencies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.competencies ALTER COLUMN id SET DEFAULT nextval('public.competencies_id_seq'::regclass);


--
-- Name: consent_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_templates ALTER COLUMN id SET DEFAULT nextval('public.consent_templates_id_seq'::regclass);


--
-- Name: data_questions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_questions ALTER COLUMN id SET DEFAULT nextval('public.data_questions_id_seq'::regclass);


--
-- Name: decisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions ALTER COLUMN id SET DEFAULT nextval('public.decisions_id_seq'::regclass);


--
-- Name: draft_answers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.draft_answers ALTER COLUMN id SET DEFAULT nextval('public.draft_answers_id_seq'::regclass);


--
-- Name: google_integration_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.google_integration_events ALTER COLUMN id SET DEFAULT nextval('public.google_integration_events_id_seq'::regclass);


--
-- Name: interviewer_invites id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interviewer_invites ALTER COLUMN id SET DEFAULT nextval('public.interviewer_invites_id_seq'::regclass);


--
-- Name: job_applications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_applications ALTER COLUMN id SET DEFAULT nextval('public.job_applications_id_seq'::regclass);


--
-- Name: job_brief_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_brief_changes ALTER COLUMN id SET DEFAULT nextval('public.job_brief_changes_id_seq'::regclass);


--
-- Name: jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs ALTER COLUMN id SET DEFAULT nextval('public.jobs_id_seq'::regclass);


--
-- Name: knockout_questions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knockout_questions ALTER COLUMN id SET DEFAULT nextval('public.knockout_questions_id_seq'::regclass);


--
-- Name: link_opens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_opens ALTER COLUMN id SET DEFAULT nextval('public.link_opens_id_seq'::regclass);


--
-- Name: link_requests id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_requests ALTER COLUMN id SET DEFAULT nextval('public.link_requests_id_seq'::regclass);


--
-- Name: mail_deliveries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mail_deliveries ALTER COLUMN id SET DEFAULT nextval('public.mail_deliveries_id_seq'::regclass);


--
-- Name: objections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.objections ALTER COLUMN id SET DEFAULT nextval('public.objections_id_seq'::regclass);


--
-- Name: offer_access_codes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_access_codes ALTER COLUMN id SET DEFAULT nextval('public.offer_access_codes_id_seq'::regclass);


--
-- Name: offer_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_documents ALTER COLUMN id SET DEFAULT nextval('public.offer_documents_id_seq'::regclass);


--
-- Name: one_time_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.one_time_links ALTER COLUMN id SET DEFAULT nextval('public.one_time_links_id_seq'::regclass);


--
-- Name: participations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participations ALTER COLUMN id SET DEFAULT nextval('public.participations_id_seq'::regclass);


--
-- Name: progression_choices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.progression_choices ALTER COLUMN id SET DEFAULT nextval('public.progression_choices_id_seq'::regclass);


--
-- Name: question_banks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks ALTER COLUMN id SET DEFAULT nextval('public.question_banks_id_seq'::regclass);


--
-- Name: requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements ALTER COLUMN id SET DEFAULT nextval('public.requirements_id_seq'::regclass);


--
-- Name: salary_agreements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_agreements ALTER COLUMN id SET DEFAULT nextval('public.salary_agreements_id_seq'::regclass);


--
-- Name: salary_recommendations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_recommendations ALTER COLUMN id SET DEFAULT nextval('public.salary_recommendations_id_seq'::regclass);


--
-- Name: score_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_entries ALTER COLUMN id SET DEFAULT nextval('public.score_entries_id_seq'::regclass);


--
-- Name: screening_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_attempts ALTER COLUMN id SET DEFAULT nextval('public.screening_attempts_id_seq'::regclass);


--
-- Name: screening_label_confirmations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_label_confirmations ALTER COLUMN id SET DEFAULT nextval('public.screening_label_confirmations_id_seq'::regclass);


--
-- Name: screening_narrative_approvals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_narrative_approvals ALTER COLUMN id SET DEFAULT nextval('public.screening_narrative_approvals_id_seq'::regclass);


--
-- Name: screening_result_erasures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_result_erasures ALTER COLUMN id SET DEFAULT nextval('public.screening_result_erasures_id_seq'::regclass);


--
-- Name: screening_results id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_results ALTER COLUMN id SET DEFAULT nextval('public.screening_results_id_seq'::regclass);


--
-- Name: screening_reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews ALTER COLUMN id SET DEFAULT nextval('public.screening_reviews_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: setting_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.setting_changes ALTER COLUMN id SET DEFAULT nextval('public.setting_changes_id_seq'::regclass);


--
-- Name: sign_in_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sign_in_events ALTER COLUMN id SET DEFAULT nextval('public.sign_in_events_id_seq'::regclass);


--
-- Name: stage_changes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_changes ALTER COLUMN id SET DEFAULT nextval('public.stage_changes_id_seq'::regclass);


--
-- Name: stage_recommendations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_recommendations ALTER COLUMN id SET DEFAULT nextval('public.stage_recommendations_id_seq'::regclass);


--
-- Name: stage_text_erasures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_text_erasures ALTER COLUMN id SET DEFAULT nextval('public.stage_text_erasures_id_seq'::regclass);


--
-- Name: stages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages ALTER COLUMN id SET DEFAULT nextval('public.stages_id_seq'::regclass);


--
-- Name: system_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings ALTER COLUMN id SET DEFAULT nextval('public.system_settings_id_seq'::regclass);


--
-- Name: test_ai_suggestions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_ai_suggestions ALTER COLUMN id SET DEFAULT nextval('public.test_ai_suggestions_id_seq'::regclass);


--
-- Name: test_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_attempts ALTER COLUMN id SET DEFAULT nextval('public.test_attempts_id_seq'::regclass);


--
-- Name: test_case_criteria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_case_criteria ALTER COLUMN id SET DEFAULT nextval('public.test_case_criteria_id_seq'::regclass);


--
-- Name: test_cases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_cases ALTER COLUMN id SET DEFAULT nextval('public.test_cases_id_seq'::regclass);


--
-- Name: test_reviews id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews ALTER COLUMN id SET DEFAULT nextval('public.test_reviews_id_seq'::regclass);


--
-- Name: user_recommendations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recommendations ALTER COLUMN id SET DEFAULT nextval('public.user_recommendations_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: activities activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);


--
-- Name: ai_release_actions ai_release_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_actions
    ADD CONSTRAINT ai_release_actions_pkey PRIMARY KEY (id);


--
-- Name: ai_release_erasures ai_release_erasures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_erasures
    ADD CONSTRAINT ai_release_erasures_pkey PRIMARY KEY (id);


--
-- Name: ai_releases ai_releases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases
    ADD CONSTRAINT ai_releases_pkey PRIMARY KEY (id);


--
-- Name: application_drafts application_drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts
    ADD CONSTRAINT application_drafts_pkey PRIMARY KEY (id);


--
-- Name: application_window_events application_window_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_window_events
    ADD CONSTRAINT application_window_events_pkey PRIMARY KEY (id);


--
-- Name: appointment_changes appointment_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_changes
    ADD CONSTRAINT appointment_changes_pkey PRIMARY KEY (id);


--
-- Name: appointments appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: bank_questions bank_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_questions
    ADD CONSTRAINT bank_questions_pkey PRIMARY KEY (id);


--
-- Name: brief_suggestions brief_suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_suggestions
    ADD CONSTRAINT brief_suggestions_pkey PRIMARY KEY (id);


--
-- Name: calibration_judgements calibration_judgements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judgements
    ADD CONSTRAINT calibration_judgements_pkey PRIMARY KEY (id);


--
-- Name: candidate_letters candidate_letters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidate_letters
    ADD CONSTRAINT candidate_letters_pkey PRIMARY KEY (id);


--
-- Name: candidates candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidates
    ADD CONSTRAINT candidates_pkey PRIMARY KEY (id);


--
-- Name: client_companies client_companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_companies
    ADD CONSTRAINT client_companies_pkey PRIMARY KEY (id);


--
-- Name: competencies competencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.competencies
    ADD CONSTRAINT competencies_pkey PRIMARY KEY (id);


--
-- Name: consent_templates consent_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_templates
    ADD CONSTRAINT consent_templates_pkey PRIMARY KEY (id);


--
-- Name: data_questions data_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_questions
    ADD CONSTRAINT data_questions_pkey PRIMARY KEY (id);


--
-- Name: decisions decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT decisions_pkey PRIMARY KEY (id);


--
-- Name: draft_answers draft_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.draft_answers
    ADD CONSTRAINT draft_answers_pkey PRIMARY KEY (id);


--
-- Name: google_integration_events google_integration_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.google_integration_events
    ADD CONSTRAINT google_integration_events_pkey PRIMARY KEY (id);


--
-- Name: interviewer_invites interviewer_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interviewer_invites
    ADD CONSTRAINT interviewer_invites_pkey PRIMARY KEY (id);


--
-- Name: job_applications job_applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_applications
    ADD CONSTRAINT job_applications_pkey PRIMARY KEY (id);


--
-- Name: job_brief_changes job_brief_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_brief_changes
    ADD CONSTRAINT job_brief_changes_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: knockout_questions knockout_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knockout_questions
    ADD CONSTRAINT knockout_questions_pkey PRIMARY KEY (id);


--
-- Name: link_opens link_opens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_opens
    ADD CONSTRAINT link_opens_pkey PRIMARY KEY (id);


--
-- Name: link_requests link_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_requests
    ADD CONSTRAINT link_requests_pkey PRIMARY KEY (id);


--
-- Name: mail_deliveries mail_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mail_deliveries
    ADD CONSTRAINT mail_deliveries_pkey PRIMARY KEY (id);


--
-- Name: objections objections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.objections
    ADD CONSTRAINT objections_pkey PRIMARY KEY (id);


--
-- Name: offer_access_codes offer_access_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_access_codes
    ADD CONSTRAINT offer_access_codes_pkey PRIMARY KEY (id);


--
-- Name: offer_documents offer_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_documents
    ADD CONSTRAINT offer_documents_pkey PRIMARY KEY (id);


--
-- Name: one_time_links one_time_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.one_time_links
    ADD CONSTRAINT one_time_links_pkey PRIMARY KEY (id);


--
-- Name: participations participations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participations
    ADD CONSTRAINT participations_pkey PRIMARY KEY (id);


--
-- Name: progression_choices progression_choices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.progression_choices
    ADD CONSTRAINT progression_choices_pkey PRIMARY KEY (id);


--
-- Name: question_banks question_banks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks
    ADD CONSTRAINT question_banks_pkey PRIMARY KEY (id);


--
-- Name: requirements requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT requirements_pkey PRIMARY KEY (id);


--
-- Name: salary_agreements salary_agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_agreements
    ADD CONSTRAINT salary_agreements_pkey PRIMARY KEY (id);


--
-- Name: salary_recommendations salary_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_recommendations
    ADD CONSTRAINT salary_recommendations_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: score_entries score_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_entries
    ADD CONSTRAINT score_entries_pkey PRIMARY KEY (id);


--
-- Name: screening_attempts screening_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_attempts
    ADD CONSTRAINT screening_attempts_pkey PRIMARY KEY (id);


--
-- Name: screening_label_confirmations screening_label_confirmations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_label_confirmations
    ADD CONSTRAINT screening_label_confirmations_pkey PRIMARY KEY (id);


--
-- Name: screening_narrative_approvals screening_narrative_approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_narrative_approvals
    ADD CONSTRAINT screening_narrative_approvals_pkey PRIMARY KEY (id);


--
-- Name: screening_result_erasures screening_result_erasures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_result_erasures
    ADD CONSTRAINT screening_result_erasures_pkey PRIMARY KEY (id);


--
-- Name: screening_results screening_results_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_results
    ADD CONSTRAINT screening_results_pkey PRIMARY KEY (id);


--
-- Name: screening_reviews screening_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews
    ADD CONSTRAINT screening_reviews_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: setting_changes setting_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.setting_changes
    ADD CONSTRAINT setting_changes_pkey PRIMARY KEY (id);


--
-- Name: sign_in_events sign_in_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sign_in_events
    ADD CONSTRAINT sign_in_events_pkey PRIMARY KEY (id);


--
-- Name: stage_changes stage_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_changes
    ADD CONSTRAINT stage_changes_pkey PRIMARY KEY (id);


--
-- Name: stage_recommendations stage_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_recommendations
    ADD CONSTRAINT stage_recommendations_pkey PRIMARY KEY (id);


--
-- Name: stage_text_erasures stage_text_erasures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_text_erasures
    ADD CONSTRAINT stage_text_erasures_pkey PRIMARY KEY (id);


--
-- Name: stages stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_pkey PRIMARY KEY (id);


--
-- Name: system_settings system_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_pkey PRIMARY KEY (id);


--
-- Name: test_ai_suggestions test_ai_suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_ai_suggestions
    ADD CONSTRAINT test_ai_suggestions_pkey PRIMARY KEY (id);


--
-- Name: test_attempts test_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_attempts
    ADD CONSTRAINT test_attempts_pkey PRIMARY KEY (id);


--
-- Name: test_case_criteria test_case_criteria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_case_criteria
    ADD CONSTRAINT test_case_criteria_pkey PRIMARY KEY (id);


--
-- Name: test_cases test_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_cases
    ADD CONSTRAINT test_cases_pkey PRIMARY KEY (id);


--
-- Name: test_reviews test_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT test_reviews_pkey PRIMARY KEY (id);


--
-- Name: user_recommendations user_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recommendations
    ADD CONSTRAINT user_recommendations_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: decisions_one_first_decision; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX decisions_one_first_decision ON public.decisions USING btree (participation_id) WHERE (supersedes_id IS NULL);


--
-- Name: idx_on_application_draft_id_bank_question_id_9391c0fb3f; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_application_draft_id_bank_question_id_9391c0fb3f ON public.draft_answers USING btree (application_draft_id, bank_question_id);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_activities_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_activities_on_job_id ON public.activities USING btree (job_id);


--
-- Name: index_ai_release_actions_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_release_actions_on_actor_id ON public.ai_release_actions USING btree (actor_id);


--
-- Name: index_ai_release_actions_on_ai_release_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_release_actions_on_ai_release_id ON public.ai_release_actions USING btree (ai_release_id);


--
-- Name: index_ai_release_erasures_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_release_erasures_on_actor_id ON public.ai_release_erasures USING btree (actor_id);


--
-- Name: index_ai_release_erasures_on_ai_release_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_release_erasures_on_ai_release_id ON public.ai_release_erasures USING btree (ai_release_id);


--
-- Name: index_ai_releases_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_releases_latest ON public.ai_releases USING btree (participation_id, payload_kind, id);


--
-- Name: index_ai_releases_on_cut_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_releases_on_cut_by_id ON public.ai_releases USING btree (cut_by_id);


--
-- Name: index_ai_releases_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_releases_on_job_id ON public.ai_releases USING btree (job_id);


--
-- Name: index_ai_releases_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_releases_on_participation_id ON public.ai_releases USING btree (participation_id);


--
-- Name: index_ai_releases_on_supersedes_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_releases_on_supersedes_id ON public.ai_releases USING btree (supersedes_id);


--
-- Name: index_application_drafts_on_consent_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_application_drafts_on_consent_template_id ON public.application_drafts USING btree (consent_template_id);


--
-- Name: index_application_drafts_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_application_drafts_on_job_application_id ON public.application_drafts USING btree (job_application_id);


--
-- Name: index_application_drafts_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_application_drafts_on_job_id ON public.application_drafts USING btree (job_id);


--
-- Name: index_application_drafts_on_question_bank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_application_drafts_on_question_bank_id ON public.application_drafts USING btree (question_bank_id);


--
-- Name: index_application_drafts_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_application_drafts_on_token_digest ON public.application_drafts USING btree (token_digest);


--
-- Name: index_application_window_events_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_application_window_events_on_job_id ON public.application_window_events USING btree (job_id);


--
-- Name: index_appointment_changes_on_appointment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_appointment_changes_on_appointment_id ON public.appointment_changes USING btree (appointment_id);


--
-- Name: index_appointments_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_appointments_on_participation_id ON public.appointments USING btree (participation_id);


--
-- Name: index_bank_questions_on_question_bank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_questions_on_question_bank_id ON public.bank_questions USING btree (question_bank_id);


--
-- Name: index_bank_questions_on_question_bank_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bank_questions_on_question_bank_id_and_position ON public.bank_questions USING btree (question_bank_id, "position");


--
-- Name: index_brief_suggestions_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_brief_suggestions_on_actor_id ON public.brief_suggestions USING btree (actor_id);


--
-- Name: index_brief_suggestions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_brief_suggestions_on_job_id ON public.brief_suggestions USING btree (job_id);


--
-- Name: index_calibration_judgements_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_judgements_on_job_id ON public.calibration_judgements USING btree (job_id);


--
-- Name: index_calibration_judgements_on_judged_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_judgements_on_judged_by_id ON public.calibration_judgements USING btree (judged_by_id);


--
-- Name: index_calibration_judgements_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calibration_judgements_on_participation_id ON public.calibration_judgements USING btree (participation_id);


--
-- Name: index_calibration_judgements_once_per_rubric; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calibration_judgements_once_per_rubric ON public.calibration_judgements USING btree (participation_id, rubric_digest);


--
-- Name: index_candidate_letters_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_candidate_letters_on_job_application_id ON public.candidate_letters USING btree (job_application_id);


--
-- Name: index_candidate_letters_on_mail_delivery_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_candidate_letters_on_mail_delivery_id ON public.candidate_letters USING btree (mail_delivery_id);


--
-- Name: index_competencies_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_competencies_on_job_id ON public.competencies USING btree (job_id);


--
-- Name: index_consent_templates_on_client_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consent_templates_on_client_company_id ON public.consent_templates USING btree (client_company_id);


--
-- Name: index_consent_templates_on_company_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consent_templates_on_company_and_version ON public.consent_templates USING btree (COALESCE(client_company_id, (0)::bigint), version);


--
-- Name: index_data_questions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_data_questions_on_user_id ON public.data_questions USING btree (user_id);


--
-- Name: index_decisions_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_decisions_on_participation_id ON public.decisions USING btree (participation_id);


--
-- Name: index_decisions_on_supersedes_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_decisions_on_supersedes_id ON public.decisions USING btree (supersedes_id);


--
-- Name: index_draft_answers_on_application_draft_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_draft_answers_on_application_draft_id ON public.draft_answers USING btree (application_draft_id);


--
-- Name: index_draft_answers_on_bank_question_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_draft_answers_on_bank_question_id ON public.draft_answers USING btree (bank_question_id);


--
-- Name: index_draft_answers_on_reviewed_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_draft_answers_on_reviewed_by_id ON public.draft_answers USING btree (reviewed_by_id);


--
-- Name: index_google_integration_events_on_integration_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_google_integration_events_on_integration_and_created_at ON public.google_integration_events USING btree (integration, created_at);


--
-- Name: index_interviewer_invites_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_interviewer_invites_on_participation_id ON public.interviewer_invites USING btree (participation_id);


--
-- Name: index_interviewer_invites_on_score_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_interviewer_invites_on_score_entry_id ON public.interviewer_invites USING btree (score_entry_id);


--
-- Name: index_job_applications_on_candidate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_job_applications_on_candidate_id ON public.job_applications USING btree (candidate_id);


--
-- Name: index_job_applications_on_consent_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_job_applications_on_consent_template_id ON public.job_applications USING btree (consent_template_id);


--
-- Name: index_job_applications_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_job_applications_on_job_id ON public.job_applications USING btree (job_id);


--
-- Name: index_job_brief_changes_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_job_brief_changes_on_job_id ON public.job_brief_changes USING btree (job_id);


--
-- Name: index_jobs_on_client_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_client_company_id ON public.jobs USING btree (client_company_id);


--
-- Name: index_jobs_on_consultant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_consultant_id ON public.jobs USING btree (consultant_id);


--
-- Name: index_jobs_on_public_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_jobs_on_public_code ON public.jobs USING btree (public_code);


--
-- Name: index_knockout_questions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_knockout_questions_on_job_id ON public.knockout_questions USING btree (job_id);


--
-- Name: index_knockout_questions_on_job_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knockout_questions_on_job_id_and_position ON public.knockout_questions USING btree (job_id, "position");


--
-- Name: index_knockout_questions_on_requirement_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_knockout_questions_on_requirement_id ON public.knockout_questions USING btree (requirement_id);


--
-- Name: index_link_opens_on_one_time_link_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_link_opens_on_one_time_link_id ON public.link_opens USING btree (one_time_link_id);


--
-- Name: index_link_requests_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_link_requests_on_job_application_id ON public.link_requests USING btree (job_application_id);


--
-- Name: index_link_requests_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_link_requests_on_job_id ON public.link_requests USING btree (job_id);


--
-- Name: index_mail_deliveries_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mail_deliveries_on_job_application_id ON public.mail_deliveries USING btree (job_application_id);


--
-- Name: index_objections_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_objections_on_participation_id ON public.objections USING btree (participation_id);


--
-- Name: index_offer_access_codes_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_offer_access_codes_on_job_application_id ON public.offer_access_codes USING btree (job_application_id);


--
-- Name: index_offer_documents_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_offer_documents_on_job_application_id ON public.offer_documents USING btree (job_application_id);


--
-- Name: index_offer_documents_on_job_application_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_offer_documents_on_job_application_id_and_version ON public.offer_documents USING btree (job_application_id, version);


--
-- Name: index_one_time_links_on_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_one_time_links_on_subject ON public.one_time_links USING btree (subject_type, subject_id);


--
-- Name: index_one_time_links_on_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_one_time_links_on_token_digest ON public.one_time_links USING btree (token_digest);


--
-- Name: index_participations_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participations_on_job_application_id ON public.participations USING btree (job_application_id);


--
-- Name: index_participations_on_job_application_id_and_stage_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_participations_on_job_application_id_and_stage_id ON public.participations USING btree (job_application_id, stage_id);


--
-- Name: index_participations_on_stage_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participations_on_stage_id ON public.participations USING btree (stage_id);


--
-- Name: index_progression_choices_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_progression_choices_on_participation_id ON public.progression_choices USING btree (participation_id);


--
-- Name: index_progression_choices_on_stage_recommendation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_progression_choices_on_stage_recommendation_id ON public.progression_choices USING btree (stage_recommendation_id);


--
-- Name: index_question_banks_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_question_banks_on_approved_by_id ON public.question_banks USING btree (approved_by_id);


--
-- Name: index_question_banks_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_question_banks_on_created_by_id ON public.question_banks USING btree (created_by_id);


--
-- Name: index_question_banks_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_question_banks_on_job_id ON public.question_banks USING btree (job_id);


--
-- Name: index_question_banks_on_job_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_question_banks_on_job_id_and_version ON public.question_banks USING btree (job_id, version);


--
-- Name: index_question_banks_on_submitted_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_question_banks_on_submitted_by_id ON public.question_banks USING btree (submitted_by_id);


--
-- Name: index_requirements_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_requirements_on_job_id ON public.requirements USING btree (job_id);


--
-- Name: index_salary_agreements_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_salary_agreements_on_job_application_id ON public.salary_agreements USING btree (job_application_id);


--
-- Name: index_salary_agreements_on_salary_recommendation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_salary_agreements_on_salary_recommendation_id ON public.salary_agreements USING btree (salary_recommendation_id);


--
-- Name: index_salary_recommendations_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_salary_recommendations_on_job_application_id ON public.salary_recommendations USING btree (job_application_id);


--
-- Name: index_score_entries_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_score_entries_on_participation_id ON public.score_entries USING btree (participation_id);


--
-- Name: index_score_entries_on_supersedes_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_score_entries_on_supersedes_id ON public.score_entries USING btree (supersedes_id);


--
-- Name: index_screening_attempts_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_attempts_on_participation_id ON public.screening_attempts USING btree (participation_id);


--
-- Name: index_screening_label_confirmations_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_label_confirmations_on_participation_id ON public.screening_label_confirmations USING btree (participation_id);


--
-- Name: index_screening_label_confirmations_on_screening_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_label_confirmations_on_screening_result_id ON public.screening_label_confirmations USING btree (screening_result_id);


--
-- Name: index_screening_narrative_approvals_on_screening_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_screening_narrative_approvals_on_screening_result_id ON public.screening_narrative_approvals USING btree (screening_result_id);


--
-- Name: index_screening_result_erasures_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_result_erasures_on_actor_id ON public.screening_result_erasures USING btree (actor_id);


--
-- Name: index_screening_result_erasures_on_screening_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_screening_result_erasures_on_screening_result_id ON public.screening_result_erasures USING btree (screening_result_id);


--
-- Name: index_screening_results_on_ai_release_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_screening_results_on_ai_release_id ON public.screening_results USING btree (ai_release_id);


--
-- Name: index_screening_results_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_results_on_participation_id ON public.screening_results USING btree (participation_id);


--
-- Name: index_screening_results_on_score_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_results_on_score_entry_id ON public.screening_results USING btree (score_entry_id);


--
-- Name: index_screening_reviews_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_reviews_on_decision_id ON public.screening_reviews USING btree (decision_id);


--
-- Name: index_screening_reviews_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_reviews_on_participation_id ON public.screening_reviews USING btree (participation_id);


--
-- Name: index_screening_reviews_on_reviewer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_screening_reviews_on_reviewer_id ON public.screening_reviews USING btree (reviewer_id);


--
-- Name: index_screening_reviews_on_screening_result_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_screening_reviews_on_screening_result_id ON public.screening_reviews USING btree (screening_result_id);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_setting_changes_on_client_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_setting_changes_on_client_company_id ON public.setting_changes USING btree (client_company_id);


--
-- Name: index_sign_in_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sign_in_events_on_user_id ON public.sign_in_events USING btree (user_id);


--
-- Name: index_stage_changes_on_stage_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stage_changes_on_stage_id ON public.stage_changes USING btree (stage_id);


--
-- Name: index_stage_recommendations_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stage_recommendations_on_participation_id ON public.stage_recommendations USING btree (participation_id);


--
-- Name: index_stage_text_erasures_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stage_text_erasures_on_actor_id ON public.stage_text_erasures USING btree (actor_id);


--
-- Name: index_stage_text_erasures_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stage_text_erasures_on_job_application_id ON public.stage_text_erasures USING btree (job_application_id);


--
-- Name: index_stage_text_erasures_on_record_type_and_record_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stage_text_erasures_on_record_type_and_record_id ON public.stage_text_erasures USING btree (record_type, record_id);


--
-- Name: index_stages_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stages_on_job_id ON public.stages USING btree (job_id);


--
-- Name: index_stages_on_job_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stages_on_job_id_and_code ON public.stages USING btree (job_id, code);


--
-- Name: index_system_settings_on_client_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_system_settings_on_client_company_id ON public.system_settings USING btree (client_company_id);


--
-- Name: index_system_settings_on_company_and_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_system_settings_on_company_and_key ON public.system_settings USING btree (COALESCE(client_company_id, (0)::bigint), key);


--
-- Name: index_test_ai_suggestions_on_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_ai_suggestions_on_actor_id ON public.test_ai_suggestions USING btree (actor_id);


--
-- Name: index_test_ai_suggestions_on_test_attempt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_ai_suggestions_on_test_attempt_id ON public.test_ai_suggestions USING btree (test_attempt_id);


--
-- Name: index_test_attempts_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_test_attempts_on_participation_id ON public.test_attempts USING btree (participation_id);


--
-- Name: index_test_attempts_on_test_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_attempts_on_test_case_id ON public.test_attempts USING btree (test_case_id);


--
-- Name: index_test_case_criteria_on_test_case_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_case_criteria_on_test_case_id ON public.test_case_criteria USING btree (test_case_id);


--
-- Name: index_test_case_criteria_on_test_case_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_test_case_criteria_on_test_case_id_and_position ON public.test_case_criteria USING btree (test_case_id, "position");


--
-- Name: index_test_cases_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_cases_on_approved_by_id ON public.test_cases USING btree (approved_by_id);


--
-- Name: index_test_cases_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_cases_on_created_by_id ON public.test_cases USING btree (created_by_id);


--
-- Name: index_test_cases_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_cases_on_job_id ON public.test_cases USING btree (job_id);


--
-- Name: index_test_cases_on_job_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_test_cases_on_job_id_and_version ON public.test_cases USING btree (job_id, version);


--
-- Name: index_test_reviews_on_decision_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_reviews_on_decision_id ON public.test_reviews USING btree (decision_id);


--
-- Name: index_test_reviews_on_participation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_test_reviews_on_participation_id ON public.test_reviews USING btree (participation_id);


--
-- Name: index_test_reviews_on_reviewer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_reviews_on_reviewer_id ON public.test_reviews USING btree (reviewer_id);


--
-- Name: index_test_reviews_on_score_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_reviews_on_score_entry_id ON public.test_reviews USING btree (score_entry_id);


--
-- Name: index_test_reviews_on_test_attempt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_test_reviews_on_test_attempt_id ON public.test_reviews USING btree (test_attempt_id);


--
-- Name: index_user_recommendations_on_job_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_recommendations_on_job_application_id ON public.user_recommendations USING btree (job_application_id);


--
-- Name: index_users_on_client_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_client_company_id ON public.users USING btree (client_company_id);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: mail_deliveries_one_test_notice; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX mail_deliveries_one_test_notice ON public.mail_deliveries USING btree (job_application_id, kind) WHERE ((kind)::text = ANY (ARRAY[('application_received'::character varying)::text, ('test_reminder'::character varying)::text, ('test_receipt'::character varying)::text, ('gate_outcome'::character varying)::text]));


--
-- Name: objections_one_open; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX objections_one_open ON public.objections USING btree (participation_id) WHERE (answered_at IS NULL);


--
-- Name: offer_documents_one_acceptance; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX offer_documents_one_acceptance ON public.offer_documents USING btree (job_application_id) WHERE ((response)::text = 'accepted'::text);


--
-- Name: stages_one_member_per_gate_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stages_one_member_per_gate_code ON public.stages USING btree (job_id, gate, code) WHERE (gate IS NOT NULL);


--
-- Name: ai_release_actions ai_release_actions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_release_actions_append_only BEFORE DELETE OR UPDATE ON public.ai_release_actions FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: ai_release_actions ai_release_actions_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_release_actions_guard BEFORE INSERT ON public.ai_release_actions FOR EACH ROW EXECUTE FUNCTION public.enforce_ai_release_action();


--
-- Name: ai_release_actions ai_release_actions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_release_actions_no_truncate BEFORE TRUNCATE ON public.ai_release_actions FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: ai_release_erasures ai_release_erasures_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_release_erasures_append_only BEFORE DELETE OR UPDATE ON public.ai_release_erasures FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: ai_release_erasures ai_release_erasures_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_release_erasures_no_truncate BEFORE TRUNCATE ON public.ai_release_erasures FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: ai_releases ai_releases_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_releases_append_only BEFORE DELETE OR UPDATE ON public.ai_releases FOR EACH ROW EXECUTE FUNCTION public.ai_releases_erase_only();


--
-- Name: ai_releases ai_releases_cut_by_reviewer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_releases_cut_by_reviewer BEFORE INSERT ON public.ai_releases FOR EACH ROW EXECUTE FUNCTION public.enforce_ai_release_cut();


--
-- Name: ai_releases ai_releases_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_releases_no_truncate BEFORE TRUNCATE ON public.ai_releases FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: application_drafts application_drafts_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER application_drafts_guard BEFORE UPDATE ON public.application_drafts FOR EACH ROW EXECUTE FUNCTION public.enforce_application_draft();


--
-- Name: application_window_events application_window_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER application_window_events_append_only BEFORE DELETE OR UPDATE ON public.application_window_events FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: application_window_events application_window_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER application_window_events_no_truncate BEFORE TRUNCATE ON public.application_window_events FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: appointment_changes appointment_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_changes_append_only BEFORE DELETE OR UPDATE ON public.appointment_changes FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: appointment_changes appointment_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER appointment_changes_no_truncate BEFORE TRUNCATE ON public.appointment_changes FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: bank_questions bank_questions_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER bank_questions_freeze BEFORE INSERT OR DELETE OR UPDATE ON public.bank_questions FOR EACH ROW EXECUTE FUNCTION public.enforce_bank_question_freeze();


--
-- Name: brief_suggestions brief_suggestions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER brief_suggestions_append_only BEFORE DELETE OR UPDATE ON public.brief_suggestions FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: brief_suggestions brief_suggestions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER brief_suggestions_no_truncate BEFORE TRUNCATE ON public.brief_suggestions FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: calibration_judgements calibration_judgements_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_judgements_append_only BEFORE DELETE OR UPDATE ON public.calibration_judgements FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: calibration_judgements calibration_judgements_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER calibration_judgements_no_truncate BEFORE TRUNCATE ON public.calibration_judgements FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: candidate_letters candidate_letters_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER candidate_letters_append_only BEFORE DELETE OR UPDATE ON public.candidate_letters FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: candidate_letters candidate_letters_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER candidate_letters_no_truncate BEFORE TRUNCATE ON public.candidate_letters FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: client_companies client_companies_single_tenant; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER client_companies_single_tenant BEFORE INSERT ON public.client_companies FOR EACH ROW EXECUTE FUNCTION public.enforce_single_tenant();


--
-- Name: consent_templates consent_templates_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER consent_templates_append_only BEFORE DELETE OR UPDATE ON public.consent_templates FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: consent_templates consent_templates_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER consent_templates_no_truncate BEFORE TRUNCATE ON public.consent_templates FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: data_questions data_questions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER data_questions_append_only BEFORE DELETE OR UPDATE ON public.data_questions FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: data_questions data_questions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER data_questions_no_truncate BEFORE TRUNCATE ON public.data_questions FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: decisions decisions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_append_only BEFORE DELETE OR UPDATE ON public.decisions FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: decisions decisions_gate_eliminated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_gate_eliminated BEFORE INSERT ON public.decisions FOR EACH ROW EXECUTE FUNCTION public.enforce_gate_eliminated();


--
-- Name: decisions decisions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_no_truncate BEFORE TRUNCATE ON public.decisions FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: decisions decisions_reopen_test_after_s1_correction; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_reopen_test_after_s1_correction AFTER INSERT ON public.decisions FOR EACH ROW EXECUTE FUNCTION public.reopen_test_after_s1_correction();


--
-- Name: decisions decisions_same_participation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER decisions_same_participation BEFORE INSERT ON public.decisions FOR EACH ROW EXECUTE FUNCTION public.enforce_same_participation_supersede();


--
-- Name: draft_answers draft_answers_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER draft_answers_guard BEFORE INSERT OR UPDATE ON public.draft_answers FOR EACH ROW EXECUTE FUNCTION public.enforce_draft_answer();


--
-- Name: draft_answers draft_answers_review_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER draft_answers_review_guard BEFORE UPDATE ON public.draft_answers FOR EACH ROW EXECUTE FUNCTION public.enforce_draft_answer_review();


--
-- Name: google_integration_events google_integration_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER google_integration_events_append_only BEFORE DELETE OR UPDATE ON public.google_integration_events FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: google_integration_events google_integration_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER google_integration_events_no_truncate BEFORE TRUNCATE ON public.google_integration_events FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: job_brief_changes job_brief_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER job_brief_changes_append_only BEFORE DELETE OR UPDATE ON public.job_brief_changes FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: job_brief_changes job_brief_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER job_brief_changes_no_truncate BEFORE TRUNCATE ON public.job_brief_changes FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: link_opens link_opens_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER link_opens_append_only BEFORE DELETE OR UPDATE ON public.link_opens FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: link_opens link_opens_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER link_opens_no_truncate BEFORE TRUNCATE ON public.link_opens FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: progression_choices progression_choices_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER progression_choices_append_only BEFORE DELETE OR UPDATE ON public.progression_choices FOR EACH ROW EXECUTE FUNCTION public.stage_text_erase_only('note', '"[dihapus]"');


--
-- Name: progression_choices progression_choices_hr_pic; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER progression_choices_hr_pic BEFORE INSERT ON public.progression_choices FOR EACH ROW EXECUTE FUNCTION public.enforce_progression_chooser();


--
-- Name: progression_choices progression_choices_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER progression_choices_no_truncate BEFORE TRUNCATE ON public.progression_choices FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: question_banks question_banks_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER question_banks_freeze BEFORE DELETE OR UPDATE ON public.question_banks FOR EACH ROW EXECUTE FUNCTION public.enforce_question_bank_freeze();


--
-- Name: question_banks question_banks_inserted_as_draft; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER question_banks_inserted_as_draft BEFORE INSERT ON public.question_banks FOR EACH ROW EXECUTE FUNCTION public.enforce_question_bank_inserted_as_draft();


--
-- Name: salary_agreements salary_agreements_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER salary_agreements_append_only BEFORE DELETE OR UPDATE ON public.salary_agreements FOR EACH ROW EXECUTE FUNCTION public.stage_text_erase_only('note', '"[dihapus]"');


--
-- Name: salary_agreements salary_agreements_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER salary_agreements_no_truncate BEFORE TRUNCATE ON public.salary_agreements FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: salary_agreements salary_agreements_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER salary_agreements_owner BEFORE INSERT ON public.salary_agreements FOR EACH ROW EXECUTE FUNCTION public.enforce_salary_decider();


--
-- Name: salary_recommendations salary_recommendations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER salary_recommendations_append_only BEFORE DELETE OR UPDATE ON public.salary_recommendations FOR EACH ROW EXECUTE FUNCTION public.stage_text_erase_only('summary', 'null', 'factors', '[]', 'problem', 'null');


--
-- Name: salary_recommendations salary_recommendations_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER salary_recommendations_no_truncate BEFORE TRUNCATE ON public.salary_recommendations FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: score_entries score_entries_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER score_entries_append_only BEFORE DELETE OR UPDATE ON public.score_entries FOR EACH ROW EXECUTE FUNCTION public.stage_text_erase_only('note', 'null');


--
-- Name: score_entries score_entries_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER score_entries_no_truncate BEFORE TRUNCATE ON public.score_entries FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: score_entries score_entries_not_after_gate_elimination; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER score_entries_not_after_gate_elimination BEFORE INSERT ON public.score_entries FOR EACH ROW EXECUTE FUNCTION public.forbid_score_after_gate_elimination();


--
-- Name: score_entries score_entries_same_participation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER score_entries_same_participation BEFORE INSERT ON public.score_entries FOR EACH ROW EXECUTE FUNCTION public.enforce_same_participation_supersede();


--
-- Name: score_entries score_entries_test_score_author; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER score_entries_test_score_author BEFORE INSERT ON public.score_entries FOR EACH ROW EXECUTE FUNCTION public.enforce_test_score_author();


--
-- Name: screening_attempts screening_attempts_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_attempts_append_only BEFORE DELETE OR UPDATE ON public.screening_attempts FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: screening_attempts screening_attempts_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_attempts_no_truncate BEFORE TRUNCATE ON public.screening_attempts FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_label_confirmations screening_label_confirmations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_label_confirmations_append_only BEFORE DELETE OR UPDATE ON public.screening_label_confirmations FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: screening_label_confirmations screening_label_confirmations_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_label_confirmations_no_truncate BEFORE TRUNCATE ON public.screening_label_confirmations FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_label_confirmations screening_label_confirmations_reviewer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_label_confirmations_reviewer BEFORE INSERT ON public.screening_label_confirmations FOR EACH ROW EXECUTE FUNCTION public.enforce_screening_reviewer();


--
-- Name: screening_label_confirmations screening_label_confirmations_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_label_confirmations_rules BEFORE INSERT ON public.screening_label_confirmations FOR EACH ROW EXECUTE FUNCTION public.enforce_label_confirmation();


--
-- Name: screening_narrative_approvals screening_narrative_approvals_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_narrative_approvals_append_only BEFORE DELETE OR UPDATE ON public.screening_narrative_approvals FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: screening_narrative_approvals screening_narrative_approvals_consultant; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_narrative_approvals_consultant BEFORE INSERT ON public.screening_narrative_approvals FOR EACH ROW EXECUTE FUNCTION public.enforce_narrative_approver();


--
-- Name: screening_narrative_approvals screening_narrative_approvals_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_narrative_approvals_no_truncate BEFORE TRUNCATE ON public.screening_narrative_approvals FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_result_erasures screening_result_erasures_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_result_erasures_append_only BEFORE DELETE OR UPDATE ON public.screening_result_erasures FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: screening_result_erasures screening_result_erasures_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_result_erasures_no_truncate BEFORE TRUNCATE ON public.screening_result_erasures FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_result_erasures screening_result_erasures_result_exists; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_result_erasures_result_exists BEFORE INSERT ON public.screening_result_erasures FOR EACH ROW EXECUTE FUNCTION public.screening_result_erasures_result_exists();


--
-- Name: screening_results screening_results_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_results_append_only BEFORE DELETE OR UPDATE ON public.screening_results FOR EACH ROW EXECUTE FUNCTION public.screening_results_erase_only();


--
-- Name: screening_results screening_results_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_results_no_truncate BEFORE TRUNCATE ON public.screening_results FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_reviews screening_reviews_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_reviews_append_only BEFORE DELETE OR UPDATE ON public.screening_reviews FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: screening_reviews screening_reviews_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_reviews_no_truncate BEFORE TRUNCATE ON public.screening_reviews FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: screening_reviews screening_reviews_reviewer_not_consultant; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screening_reviews_reviewer_not_consultant BEFORE INSERT ON public.screening_reviews FOR EACH ROW EXECUTE FUNCTION public.enforce_screening_reviewer();


--
-- Name: setting_changes setting_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER setting_changes_append_only BEFORE DELETE OR UPDATE ON public.setting_changes FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: setting_changes setting_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER setting_changes_no_truncate BEFORE TRUNCATE ON public.setting_changes FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: sign_in_events sign_in_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sign_in_events_append_only BEFORE DELETE OR UPDATE ON public.sign_in_events FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: sign_in_events sign_in_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sign_in_events_no_truncate BEFORE TRUNCATE ON public.sign_in_events FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: stage_changes stage_changes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_changes_append_only BEFORE DELETE OR UPDATE ON public.stage_changes FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: stage_changes stage_changes_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_changes_no_truncate BEFORE TRUNCATE ON public.stage_changes FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: stage_recommendations stage_recommendations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_recommendations_append_only BEFORE DELETE OR UPDATE ON public.stage_recommendations FOR EACH ROW EXECUTE FUNCTION public.stage_text_erase_only('summary', 'null', 'reasons', '{}', 'problem', 'null');


--
-- Name: stage_recommendations stage_recommendations_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_recommendations_no_truncate BEFORE TRUNCATE ON public.stage_recommendations FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: stage_text_erasures stage_text_erasures_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_text_erasures_append_only BEFORE DELETE OR UPDATE ON public.stage_text_erasures FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: stage_text_erasures stage_text_erasures_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stage_text_erasures_no_truncate BEFORE TRUNCATE ON public.stage_text_erasures FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: stages stages_gate_fixed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stages_gate_fixed BEFORE UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.enforce_stage_gate_fixed();


--
-- Name: stages stages_gate_status_together; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER stages_gate_status_together AFTER INSERT OR UPDATE ON public.stages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_gate_status_together();


--
-- Name: stages stages_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stages_lifecycle BEFORE UPDATE ON public.stages FOR EACH ROW EXECUTE FUNCTION public.enforce_stage_lifecycle();


--
-- Name: test_ai_suggestions test_ai_suggestions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_ai_suggestions_append_only BEFORE DELETE OR UPDATE ON public.test_ai_suggestions FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: test_ai_suggestions test_ai_suggestions_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_ai_suggestions_no_truncate BEFORE TRUNCATE ON public.test_ai_suggestions FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: active_storage_attachments test_answer_file_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_answer_file_freeze BEFORE INSERT OR DELETE OR UPDATE ON public.active_storage_attachments FOR EACH ROW EXECUTE FUNCTION public.enforce_test_answer_file_freeze();


--
-- Name: test_attempts test_attempts_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_attempts_guard BEFORE INSERT OR DELETE OR UPDATE ON public.test_attempts FOR EACH ROW EXECUTE FUNCTION public.enforce_test_attempt();


--
-- Name: test_attempts test_attempts_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_attempts_no_truncate BEFORE TRUNCATE ON public.test_attempts FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: test_case_criteria test_case_criteria_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_case_criteria_freeze BEFORE INSERT OR DELETE OR UPDATE ON public.test_case_criteria FOR EACH ROW EXECUTE FUNCTION public.enforce_test_case_criteria_freeze();


--
-- Name: test_case_criteria test_case_criteria_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_case_criteria_no_truncate BEFORE TRUNCATE ON public.test_case_criteria FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: active_storage_attachments test_case_file_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_case_file_freeze BEFORE INSERT OR DELETE OR UPDATE ON public.active_storage_attachments FOR EACH ROW EXECUTE FUNCTION public.enforce_test_case_file_freeze();


--
-- Name: test_cases test_cases_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_cases_freeze BEFORE DELETE OR UPDATE ON public.test_cases FOR EACH ROW EXECUTE FUNCTION public.enforce_test_case_freeze();


--
-- Name: test_cases test_cases_inserted_as_draft; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_cases_inserted_as_draft BEFORE INSERT ON public.test_cases FOR EACH ROW EXECUTE FUNCTION public.enforce_test_case_inserted_as_draft();


--
-- Name: test_cases test_cases_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_cases_no_truncate BEFORE TRUNCATE ON public.test_cases FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: test_reviews test_reviews_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_reviews_no_truncate BEFORE TRUNCATE ON public.test_reviews FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: test_reviews test_reviews_reviewer_not_consultant; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER test_reviews_reviewer_not_consultant BEFORE INSERT OR DELETE OR UPDATE ON public.test_reviews FOR EACH ROW EXECUTE FUNCTION public.enforce_test_reviewer();


--
-- Name: user_recommendations user_recommendations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_recommendations_append_only BEFORE DELETE OR UPDATE ON public.user_recommendations FOR EACH ROW EXECUTE FUNCTION public.forbid_update_delete();


--
-- Name: user_recommendations user_recommendations_hr_pic; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_recommendations_hr_pic BEFORE INSERT ON public.user_recommendations FOR EACH ROW EXECUTE FUNCTION public.enforce_user_recommendation_actor();


--
-- Name: user_recommendations user_recommendations_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_recommendations_no_truncate BEFORE TRUNCATE ON public.user_recommendations FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_truncate();


--
-- Name: draft_answers fk_rails_00440600a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.draft_answers
    ADD CONSTRAINT fk_rails_00440600a4 FOREIGN KEY (application_draft_id) REFERENCES public.application_drafts(id);


--
-- Name: screening_reviews fk_rails_08dfe02abe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews
    ADD CONSTRAINT fk_rails_08dfe02abe FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: decisions fk_rails_0a2ac40dd6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_0a2ac40dd6 FOREIGN KEY (supersedes_id) REFERENCES public.decisions(id);


--
-- Name: screening_results fk_rails_0cd74ceac9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_results
    ADD CONSTRAINT fk_rails_0cd74ceac9 FOREIGN KEY (score_entry_id) REFERENCES public.score_entries(id);


--
-- Name: test_ai_suggestions fk_rails_0ceea278d7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_ai_suggestions
    ADD CONSTRAINT fk_rails_0ceea278d7 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: question_banks fk_rails_0e23dada4b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks
    ADD CONSTRAINT fk_rails_0e23dada4b FOREIGN KEY (approved_by_id) REFERENCES public.users(id);


--
-- Name: salary_recommendations fk_rails_0e428dfe6a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_recommendations
    ADD CONSTRAINT fk_rails_0e428dfe6a FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: salary_recommendations fk_rails_0fc27940eb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_recommendations
    ADD CONSTRAINT fk_rails_0fc27940eb FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: sign_in_events fk_rails_15c491e0df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sign_in_events
    ADD CONSTRAINT fk_rails_15c491e0df FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: job_applications fk_rails_15ca77564d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_applications
    ADD CONSTRAINT fk_rails_15ca77564d FOREIGN KEY (consent_template_id) REFERENCES public.consent_templates(id);


--
-- Name: candidate_letters fk_rails_1655a93e81; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidate_letters
    ADD CONSTRAINT fk_rails_1655a93e81 FOREIGN KEY (mail_delivery_id) REFERENCES public.mail_deliveries(id);


--
-- Name: participations fk_rails_1ab8a65e3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participations
    ADD CONSTRAINT fk_rails_1ab8a65e3f FOREIGN KEY (stage_id) REFERENCES public.stages(id);


--
-- Name: test_reviews fk_rails_1b1fc1a3c8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT fk_rails_1b1fc1a3c8 FOREIGN KEY (test_attempt_id) REFERENCES public.test_attempts(id);


--
-- Name: stage_recommendations fk_rails_20b8894eea; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_recommendations
    ADD CONSTRAINT fk_rails_20b8894eea FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: draft_answers fk_rails_2592406a30; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.draft_answers
    ADD CONSTRAINT fk_rails_2592406a30 FOREIGN KEY (bank_question_id) REFERENCES public.bank_questions(id);


--
-- Name: consent_templates fk_rails_27effac501; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consent_templates
    ADD CONSTRAINT fk_rails_27effac501 FOREIGN KEY (client_company_id) REFERENCES public.client_companies(id);


--
-- Name: bank_questions fk_rails_2a650172c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_questions
    ADD CONSTRAINT fk_rails_2a650172c2 FOREIGN KEY (question_bank_id) REFERENCES public.question_banks(id);


--
-- Name: link_opens fk_rails_2c00790a34; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_opens
    ADD CONSTRAINT fk_rails_2c00790a34 FOREIGN KEY (one_time_link_id) REFERENCES public.one_time_links(id);


--
-- Name: screening_reviews fk_rails_2c1dda946f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews
    ADD CONSTRAINT fk_rails_2c1dda946f FOREIGN KEY (screening_result_id) REFERENCES public.screening_results(id);


--
-- Name: ai_releases fk_rails_2ca45e2f49; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases
    ADD CONSTRAINT fk_rails_2ca45e2f49 FOREIGN KEY (supersedes_id) REFERENCES public.ai_releases(id);


--
-- Name: score_entries fk_rails_2d584f0ee7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_entries
    ADD CONSTRAINT fk_rails_2d584f0ee7 FOREIGN KEY (supersedes_id) REFERENCES public.score_entries(id);


--
-- Name: screening_label_confirmations fk_rails_2d9537ea28; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_label_confirmations
    ADD CONSTRAINT fk_rails_2d9537ea28 FOREIGN KEY (reviewer_id) REFERENCES public.users(id);


--
-- Name: system_settings fk_rails_2e5ef2c3e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT fk_rails_2e5ef2c3e9 FOREIGN KEY (client_company_id) REFERENCES public.client_companies(id);


--
-- Name: test_attempts fk_rails_2f6e356a49; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_attempts
    ADD CONSTRAINT fk_rails_2f6e356a49 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: application_drafts fk_rails_32d3627049; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts
    ADD CONSTRAINT fk_rails_32d3627049 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: jobs fk_rails_337fe738b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_337fe738b9 FOREIGN KEY (consultant_id) REFERENCES public.users(id);


--
-- Name: jobs fk_rails_3f4145df77; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT fk_rails_3f4145df77 FOREIGN KEY (client_company_id) REFERENCES public.client_companies(id);


--
-- Name: stage_changes fk_rails_3fc0102477; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_changes
    ADD CONSTRAINT fk_rails_3fc0102477 FOREIGN KEY (stage_id) REFERENCES public.stages(id);


--
-- Name: knockout_questions fk_rails_40fd918471; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knockout_questions
    ADD CONSTRAINT fk_rails_40fd918471 FOREIGN KEY (requirement_id) REFERENCES public.requirements(id);


--
-- Name: question_banks fk_rails_4158dcf492; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks
    ADD CONSTRAINT fk_rails_4158dcf492 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: ai_release_actions fk_rails_429e41ce6d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_actions
    ADD CONSTRAINT fk_rails_429e41ce6d FOREIGN KEY (ai_release_id) REFERENCES public.ai_releases(id);


--
-- Name: test_reviews fk_rails_482100b96c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT fk_rails_482100b96c FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: draft_answers fk_rails_53aeb03aa9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.draft_answers
    ADD CONSTRAINT fk_rails_53aeb03aa9 FOREIGN KEY (reviewed_by_id) REFERENCES public.users(id);


--
-- Name: data_questions fk_rails_54d54adcf4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_questions
    ADD CONSTRAINT fk_rails_54d54adcf4 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: screening_results fk_rails_582102cfa3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_results
    ADD CONSTRAINT fk_rails_582102cfa3 FOREIGN KEY (ai_release_id) REFERENCES public.ai_releases(id);


--
-- Name: stage_text_erasures fk_rails_5908ea9875; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_text_erasures
    ADD CONSTRAINT fk_rails_5908ea9875 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: screening_label_confirmations fk_rails_5aa6f1a6f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_label_confirmations
    ADD CONSTRAINT fk_rails_5aa6f1a6f1 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: appointments fk_rails_62edc46c48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_rails_62edc46c48 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: ai_releases fk_rails_63aeb24e52; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases
    ADD CONSTRAINT fk_rails_63aeb24e52 FOREIGN KEY (cut_by_id) REFERENCES public.users(id);


--
-- Name: calibration_judgements fk_rails_6666a471bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judgements
    ADD CONSTRAINT fk_rails_6666a471bb FOREIGN KEY (judged_by_id) REFERENCES public.users(id);


--
-- Name: link_requests fk_rails_67bf25a6e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_requests
    ADD CONSTRAINT fk_rails_67bf25a6e3 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: users fk_rails_6ebadf0aca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_6ebadf0aca FOREIGN KEY (client_company_id) REFERENCES public.client_companies(id);


--
-- Name: application_drafts fk_rails_6f7f67051e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts
    ADD CONSTRAINT fk_rails_6f7f67051e FOREIGN KEY (consent_template_id) REFERENCES public.consent_templates(id);


--
-- Name: screening_result_erasures fk_rails_6f92633783; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_result_erasures
    ADD CONSTRAINT fk_rails_6f92633783 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: candidate_letters fk_rails_7078895228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidate_letters
    ADD CONSTRAINT fk_rails_7078895228 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: interviewer_invites fk_rails_711100b7b9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interviewer_invites
    ADD CONSTRAINT fk_rails_711100b7b9 FOREIGN KEY (score_entry_id) REFERENCES public.score_entries(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: screening_attempts fk_rails_790ca73241; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_attempts
    ADD CONSTRAINT fk_rails_790ca73241 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: brief_suggestions fk_rails_796793f19f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_suggestions
    ADD CONSTRAINT fk_rails_796793f19f FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: offer_documents fk_rails_7ba2442bcf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_documents
    ADD CONSTRAINT fk_rails_7ba2442bcf FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: screening_reviews fk_rails_7bdfb9912f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews
    ADD CONSTRAINT fk_rails_7bdfb9912f FOREIGN KEY (reviewer_id) REFERENCES public.users(id);


--
-- Name: salary_agreements fk_rails_812b58b7db; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_agreements
    ADD CONSTRAINT fk_rails_812b58b7db FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: candidate_letters fk_rails_8287f53998; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.candidate_letters
    ADD CONSTRAINT fk_rails_8287f53998 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: job_applications fk_rails_82b18fab66; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_applications
    ADD CONSTRAINT fk_rails_82b18fab66 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: ai_release_actions fk_rails_83f4e997f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_actions
    ADD CONSTRAINT fk_rails_83f4e997f2 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: test_case_criteria fk_rails_84a16dd81d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_case_criteria
    ADD CONSTRAINT fk_rails_84a16dd81d FOREIGN KEY (test_case_id) REFERENCES public.test_cases(id);


--
-- Name: test_reviews fk_rails_84b695138b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT fk_rails_84b695138b FOREIGN KEY (score_entry_id) REFERENCES public.score_entries(id);


--
-- Name: progression_choices fk_rails_868f6a6388; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.progression_choices
    ADD CONSTRAINT fk_rails_868f6a6388 FOREIGN KEY (stage_recommendation_id) REFERENCES public.stage_recommendations(id);


--
-- Name: participations fk_rails_874f6122dc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participations
    ADD CONSTRAINT fk_rails_874f6122dc FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: brief_suggestions fk_rails_8e18d7f35d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brief_suggestions
    ADD CONSTRAINT fk_rails_8e18d7f35d FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: test_cases fk_rails_93b43d875b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_cases
    ADD CONSTRAINT fk_rails_93b43d875b FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: test_attempts fk_rails_9903493c1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_attempts
    ADD CONSTRAINT fk_rails_9903493c1f FOREIGN KEY (test_case_id) REFERENCES public.test_cases(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: interviewer_invites fk_rails_9dd53c8e66; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interviewer_invites
    ADD CONSTRAINT fk_rails_9dd53c8e66 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: screening_results fk_rails_a29cb75199; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_results
    ADD CONSTRAINT fk_rails_a29cb75199 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: requirements fk_rails_a475267b7d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT fk_rails_a475267b7d FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: application_drafts fk_rails_aa698f9cff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts
    ADD CONSTRAINT fk_rails_aa698f9cff FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: stage_recommendations fk_rails_acca7f3ecb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_recommendations
    ADD CONSTRAINT fk_rails_acca7f3ecb FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: application_drafts fk_rails_afc66c2364; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_drafts
    ADD CONSTRAINT fk_rails_afc66c2364 FOREIGN KEY (question_bank_id) REFERENCES public.question_banks(id);


--
-- Name: test_reviews fk_rails_b47a58df5c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT fk_rails_b47a58df5c FOREIGN KEY (reviewer_id) REFERENCES public.users(id);


--
-- Name: decisions fk_rails_b4c3f6d325; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.decisions
    ADD CONSTRAINT fk_rails_b4c3f6d325 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: stages fk_rails_b652153798; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT fk_rails_b652153798 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: knockout_questions fk_rails_b73cf364d8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knockout_questions
    ADD CONSTRAINT fk_rails_b73cf364d8 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: interviewer_invites fk_rails_bad10333aa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interviewer_invites
    ADD CONSTRAINT fk_rails_bad10333aa FOREIGN KEY (issued_by_id) REFERENCES public.users(id);


--
-- Name: test_reviews fk_rails_be90d965ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_reviews
    ADD CONSTRAINT fk_rails_be90d965ca FOREIGN KEY (decision_id) REFERENCES public.decisions(id);


--
-- Name: stage_text_erasures fk_rails_c18c269c89; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_text_erasures
    ADD CONSTRAINT fk_rails_c18c269c89 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: question_banks fk_rails_c2b3f502a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks
    ADD CONSTRAINT fk_rails_c2b3f502a7 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: screening_reviews fk_rails_c6070ec88c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_reviews
    ADD CONSTRAINT fk_rails_c6070ec88c FOREIGN KEY (decision_id) REFERENCES public.decisions(id);


--
-- Name: score_entries fk_rails_cb2d735cbe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.score_entries
    ADD CONSTRAINT fk_rails_cb2d735cbe FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: test_ai_suggestions fk_rails_cb4b971448; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_ai_suggestions
    ADD CONSTRAINT fk_rails_cb4b971448 FOREIGN KEY (test_attempt_id) REFERENCES public.test_attempts(id);


--
-- Name: objections fk_rails_cb92b261d6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.objections
    ADD CONSTRAINT fk_rails_cb92b261d6 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: test_cases fk_rails_cc942f7b6b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_cases
    ADD CONSTRAINT fk_rails_cc942f7b6b FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: progression_choices fk_rails_ce46759200; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.progression_choices
    ADD CONSTRAINT fk_rails_ce46759200 FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: ai_release_erasures fk_rails_ce5f94344b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_erasures
    ADD CONSTRAINT fk_rails_ce5f94344b FOREIGN KEY (ai_release_id) REFERENCES public.ai_releases(id);


--
-- Name: mail_deliveries fk_rails_d047f72791; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mail_deliveries
    ADD CONSTRAINT fk_rails_d047f72791 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: job_applications fk_rails_d46c0518d9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_applications
    ADD CONSTRAINT fk_rails_d46c0518d9 FOREIGN KEY (candidate_id) REFERENCES public.candidates(id);


--
-- Name: link_requests fk_rails_d693148116; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.link_requests
    ADD CONSTRAINT fk_rails_d693148116 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: setting_changes fk_rails_d6e2727e2e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.setting_changes
    ADD CONSTRAINT fk_rails_d6e2727e2e FOREIGN KEY (client_company_id) REFERENCES public.client_companies(id);


--
-- Name: user_recommendations fk_rails_da9ff09a63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recommendations
    ADD CONSTRAINT fk_rails_da9ff09a63 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: job_brief_changes fk_rails_dab4340cb4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_brief_changes
    ADD CONSTRAINT fk_rails_dab4340cb4 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: salary_agreements fk_rails_dfd9e9eabc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_agreements
    ADD CONSTRAINT fk_rails_dfd9e9eabc FOREIGN KEY (decided_by_id) REFERENCES public.users(id);


--
-- Name: competencies fk_rails_e2ce007a1c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.competencies
    ADD CONSTRAINT fk_rails_e2ce007a1c FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: user_recommendations fk_rails_e38505e15a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_recommendations
    ADD CONSTRAINT fk_rails_e38505e15a FOREIGN KEY (entered_by_id) REFERENCES public.users(id);


--
-- Name: screening_narrative_approvals fk_rails_e462bd659d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screening_narrative_approvals
    ADD CONSTRAINT fk_rails_e462bd659d FOREIGN KEY (approved_by_id) REFERENCES public.users(id);


--
-- Name: progression_choices fk_rails_e52129f270; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.progression_choices
    ADD CONSTRAINT fk_rails_e52129f270 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: calibration_judgements fk_rails_e646e04485; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judgements
    ADD CONSTRAINT fk_rails_e646e04485 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: offer_access_codes fk_rails_e823c6f5e3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_access_codes
    ADD CONSTRAINT fk_rails_e823c6f5e3 FOREIGN KEY (job_application_id) REFERENCES public.job_applications(id);


--
-- Name: application_window_events fk_rails_eb2cea008b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_window_events
    ADD CONSTRAINT fk_rails_eb2cea008b FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: test_cases fk_rails_ef7b4c36b0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.test_cases
    ADD CONSTRAINT fk_rails_ef7b4c36b0 FOREIGN KEY (approved_by_id) REFERENCES public.users(id);


--
-- Name: question_banks fk_rails_f29eee3975; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_banks
    ADD CONSTRAINT fk_rails_f29eee3975 FOREIGN KEY (submitted_by_id) REFERENCES public.users(id);


--
-- Name: ai_releases fk_rails_f2d352ad63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases
    ADD CONSTRAINT fk_rails_f2d352ad63 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: calibration_judgements fk_rails_f324b5d125; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calibration_judgements
    ADD CONSTRAINT fk_rails_f324b5d125 FOREIGN KEY (participation_id) REFERENCES public.participations(id);


--
-- Name: salary_agreements fk_rails_f3c1b7d29a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salary_agreements
    ADD CONSTRAINT fk_rails_f3c1b7d29a FOREIGN KEY (salary_recommendation_id) REFERENCES public.salary_recommendations(id);


--
-- Name: ai_release_erasures fk_rails_f4a6e71bee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_release_erasures
    ADD CONSTRAINT fk_rails_f4a6e71bee FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: appointment_changes fk_rails_fa3a24c49c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_changes
    ADD CONSTRAINT fk_rails_fa3a24c49c FOREIGN KEY (appointment_id) REFERENCES public.appointments(id);


--
-- Name: activities fk_rails_fdf950c487; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT fk_rails_fdf950c487 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: ai_releases fk_rails_ffbf380a11; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_releases
    ADD CONSTRAINT fk_rails_ffbf380a11 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261017130000'),
('20261017120000'),
('20261017113000'),
('20261017110000'),
('20261017100000'),
('20261016091000'),
('20261016090000'),
('20261016081000'),
('20261016080000'),
('20261016070000'),
('20261012210000'),
('20261012200000'),
('20261011130000'),
('20261011120000'),
('20261011110000'),
('20261011100000'),
('20261011090000'),
('20261011062610'),
('20261011054424'),
('20261011030815'),
('20261011022151'),
('20261011021314'),
('20261010223500'),
('20261010223000'),
('20261010221500'),
('20261010221000'),
('20261010200000'),
('20261010190724'),
('20261010190000'),
('20261010184500'),
('20261010173500'),
('20261010000032'),
('20261010000031'),
('20261010000030'),
('20261010000018'),
('20261010000017'),
('20261010000016'),
('20261010000015'),
('20261010000014'),
('20261010000013'),
('20261010000012'),
('20261010000011'),
('20261010000010'),
('20261010000008'),
('20261010000007'),
('20261010000006'),
('20261010000005'),
('20261010000004'),
('20261010000003'),
('20261010000002'),
('20261010000001'),
('20261010000000'),
('20261001000002'),
('20261001000001');

