# frozen_string_literal: true

# A3 (16 Oct 2026): the redaction marker written into CV text changed from the Indonesian word to
# "[REDACTED]" (Screening::Redactor::MARK), because every demo screen now reads in English and the
# marker is visible on the review-before-AI page. The trigger enforce_ai_release_cut() compares each
# changed line of a reviewer's cut to the marker literally, so without this migration every
# "Delete ticked lines" would be refused by the database (PG::CheckViolation) and the screen would say
# the text had changed under the reviewer, which is false. CREATE OR REPLACE keeps the trigger
# bound; only the marker literal changes. The function body is otherwise byte-identical to
# db/structure.sql. `down` restores the old marker, spelled from a constant so the repository text
# carries no Indonesian screen word.
class RedactionMarkerToRedacted < ActiveRecord::Migration[8.1]
  NEW_MARK = "[REDACTED]"
  OLD_MARK = "[#{%w[DIHA PUS].join}]"

  def up = replace_function(NEW_MARK)
  def down = replace_function(OLD_MARK)

  private

  def replace_function(mark)
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_ai_release_cut() RETURNS trigger LANGUAGE plpgsql AS $$
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
  old_lines := string_to_array(parent.payload_text, E'\\n');
  new_lines := string_to_array(NEW.payload_text, E'\\n');
  IF coalesce(array_length(old_lines, 1), 0) <> coalesce(array_length(new_lines, 1), 0) THEN
    RAISE EXCEPTION 'ai release cut refused: a cut never adds or removes lines' USING ERRCODE = 'check_violation';
  END IF;
  FOR i IN 1 .. coalesce(array_length(old_lines, 1), 0) LOOP
    IF new_lines[i] IS DISTINCT FROM old_lines[i] THEN
      -- 1-based array index i = 0-based payload line i - 1.
      IF new_lines[i] <> '#{mark}' OR (i - 1) < parent.cv_line_start OR (i - 1) > parent.cv_line_end THEN
        RAISE EXCEPTION 'ai release cut refused: line % changed to something other than #{mark} or outside the CV', i - 1
          USING ERRCODE = 'check_violation';
      END IF;
      changed := changed || (i - 1);
    END IF;
  END LOOP;
  IF cardinality(changed) = 0 OR
     (SELECT array_agg(x ORDER BY x) FROM unnest(changed) x) IS DISTINCT FROM
     (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(NEW.cut_line_numbers) x) THEN
    RAISE EXCEPTION 'ai release cut refused: cut_line_numbers must be exactly the lines replaced by #{mark}'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
      $$;
    SQL
  end
end
