# Feature 09, test engine run 1 (F09-02, F09-03). Additive: one new append-only table, one relaxed
# NOT NULL, a CHECK replaced by a superset, and three trigger functions replaced by stricter ones.
#
# F09-02  enforce_ai_release_cut() checked WHO cut, never WHAT changed, so a direct INSERT of a
#         "cut" could ADD text. It now compares the new version with the one it supersedes, line by
#         line: same line count, every line identical or exactly "[DIHAPUS]", a "[DIHAPUS]" only on
#         a CV line (the requirements never change), the changed lines are exactly cut_line_numbers,
#         and every other column (participation, job, kind, CV line range, rubric and source digests)
#         is the superseded version's. An erased version cannot be cut.
#
# F09-03  UU 27/2022 (PDP): the release texts must be erasable when consent is withdrawn (Pasal 40),
#         when no consent was ever given (D16) and when the retention period ends (D32, blueprint
#         §4.2). ai_releases was strictly append-only, so they never could be. Now:
#           - ai_release_erasures: who (NULL = the system or the candidate's own withdrawal), when,
#             why (retention_expired | consent_withdrawn | no_consent), one per release version;
#             append-only itself. Same shape as feature 11's retention_blankings (D63 builder agreed
#             by message: one shape, per record, reason names shared).
#           - ai_releases.payload_text may be NULL (erased). The digest CHECK holds for every text
#             that still exists.
#           - The ONLY change the database allows on an ai_releases row: payload_text set to NULL
#             (an empty string or "[DIHAPUS — retensi]" is normalised to NULL). payload_sha256, who,
#             when and every other column stay exactly as they were (the trigger keeps the old
#             digest even if a statement tries to change it). DELETE stays refused.
#           - Allowed only when an erasure row names the version, or the application's consent is
#             withdrawn / was never given, in which case the trigger WRITES the erasure row itself
#             (reason from the application, actor NULL), so no blanked row is ever without a record.
#           - An erased version can never be released (action trigger) or cut (cut trigger).
#         The trigger keeps the name ai_releases_append_only on purpose: other code and tests refer
#         to it by that name (the engine's tamper helper disables it inside a rolled-back test).
class HardenAiReleaseGate < ActiveRecord::Migration[8.1]
  MARK = "[DIHAPUS]".freeze

  def up
    create_table :ai_release_erasures do |t|
      t.references :ai_release, null: false, foreign_key: true, index: { unique: true }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :reason, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_check_constraint :ai_release_erasures, "reason IN ('retention_expired','consent_withdrawn','no_consent')",
                         name: "ai_release_erasures_reason"
    execute <<~SQL
      CREATE TRIGGER ai_release_erasures_append_only BEFORE UPDATE OR DELETE ON ai_release_erasures
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER ai_release_erasures_no_truncate BEFORE TRUNCATE ON ai_release_erasures
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
    SQL

    change_column_null :ai_releases, :payload_text, true
    remove_check_constraint :ai_releases, name: "ai_releases_digest_matches_text"
    add_check_constraint :ai_releases,
                         "payload_text IS NULL OR payload_sha256 = encode(sha256(convert_to(payload_text, 'UTF8')), 'hex')",
                         name: "ai_releases_digest_matches_text"

    execute <<~SQL
      CREATE FUNCTION ai_releases_erase_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
      DECLARE
        app job_applications%ROWTYPE;
        basis text;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'ai_releases is append-only: DELETE refused' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.payload_text IS NOT NULL AND NEW.payload_text NOT IN ('', '[DIHAPUS — retensi]') THEN
          RAISE EXCEPTION 'ai_releases: the only change allowed is erasing payload_text' USING ERRCODE = 'restrict_violation';
        END IF;
        NEW.payload_text := NULL;
        NEW.payload_sha256 := OLD.payload_sha256;
        IF (to_jsonb(NEW) - 'payload_text') IS DISTINCT FROM (to_jsonb(OLD) - 'payload_text') THEN
          RAISE EXCEPTION 'ai_releases: only payload_text may be erased' USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.payload_text IS NULL THEN
          RETURN NEW;  -- already erased: a no-op
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ai_release_erasures WHERE ai_release_id = OLD.id) THEN
          SELECT ja.* INTO app FROM job_applications ja JOIN participations p ON p.job_application_id = ja.id
            WHERE p.id = OLD.participation_id;
          IF app.consent_withdrawn_at IS NOT NULL THEN
            basis := 'consent_withdrawn';
          ELSIF app.consent_at IS NULL OR app.status = 'no_consent' THEN
            basis := 'no_consent';
          ELSE
            RAISE EXCEPTION 'ai_releases: erasing release % needs an ai_release_erasures row (retention end) or withdrawn consent', OLD.id
              USING ERRCODE = 'restrict_violation';
          END IF;
          INSERT INTO ai_release_erasures (ai_release_id, actor_id, reason, note, created_at)
            VALUES (OLD.id, NULL, basis, 'Dicatat oleh basis data saat teks dihapus', now());
        END IF;
        RETURN NEW;
      END;
      $$;
      DROP TRIGGER ai_releases_append_only ON ai_releases;
      CREATE TRIGGER ai_releases_append_only BEFORE UPDATE OR DELETE ON ai_releases
        FOR EACH ROW EXECUTE FUNCTION ai_releases_erase_only();

      CREATE OR REPLACE FUNCTION enforce_ai_release_cut() RETURNS trigger
        LANGUAGE plpgsql AS $$
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
            IF new_lines[i] <> '#{MARK}' OR (i - 1) < parent.cv_line_start OR (i - 1) > parent.cv_line_end THEN
              RAISE EXCEPTION 'ai release cut refused: line % changed to something other than [DIHAPUS] or outside the CV', i - 1
                USING ERRCODE = 'check_violation';
            END IF;
            changed := changed || (i - 1);
          END IF;
        END LOOP;
        IF cardinality(changed) = 0 OR
           (SELECT array_agg(x ORDER BY x) FROM unnest(changed) x) IS DISTINCT FROM
           (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(NEW.cut_line_numbers) x) THEN
          RAISE EXCEPTION 'ai release cut refused: cut_line_numbers must be exactly the lines replaced by [DIHAPUS]'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$;

      CREATE OR REPLACE FUNCTION enforce_ai_release_action() RETURNS trigger
        LANGUAGE plpgsql AS $$
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
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "erased release texts cannot be restored; never roll this back on a database with real data"
  end
end
