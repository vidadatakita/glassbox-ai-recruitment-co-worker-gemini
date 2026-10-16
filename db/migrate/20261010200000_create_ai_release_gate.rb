# Feature 09, decision D51 (AI privacy policy A + B + C): the human release step in front of every
# Gemini API call. Additive only: two new append-only tables, two nullable columns, and a WIDER
# participations.screening_state CHECK (a superset; every existing row stays valid).
#
#   ai_releases          one row per payload VERSION that could be sent to the AI. The row holds
#                        the exact request text (payload_text) and its SHA-256. A reviewer's cut
#                        ("Hapus bagian") is a NEW row that supersedes the old one; rows are never
#                        updated. Kind cv_screening now; interview_note and stage_recommendation
#                        are reserved for D63 so it needs no new CHECK.
#   ai_release_actions   the person's decision on one version: released ("Kirim ke AI") or declined
#                        ("Tidak dikirim — putuskan manual"). One per version.
#   screening_results.ai_release_id   which released payload produced the result (pilot measure C,
#                        and "consumed": a release is sent for at most one stored result).
#
# Database guards (a service check can be bypassed by any other code path that inserts a row):
#   - payload_sha256 must equal sha256(payload_text), computed by PostgreSQL itself;
#   - the actor of an action, and the person who cuts, must be a reviewer and never the job's
#     consultant (same rule as screening_reviews, feature 06);
#   - a "released" action must carry the version's own digest, the version must be the latest for
#     its participation and kind, and its residual-check findings must be empty (fail closed, ADR
#     0004): a version with an ID-number, phone, date-of-birth, email, label or name shape can
#     never be released, only cut further or declined;
#   - a decided version cannot be cut.
class CreateAiReleaseGate < ActiveRecord::Migration[8.1]
  KINDS = %w[cv_screening interview_note stage_recommendation].freeze

  def up
    create_table :ai_releases do |t|
      t.references :participation, null: false, foreign_key: true
      t.references :job, null: false, foreign_key: true
      t.string :payload_kind, null: false
      # The user-message text exactly as the API call will send it (Screening::AiClient
      # .user_content): the requirements JSON and the redacted CV. Personal data under UU PDP: never
      # logged; shown only to reviewers.
      t.text :payload_text, null: false
      t.string :payload_sha256, null: false
      # 0-based line numbers (inside payload_text) of the first and last CV line. Only these lines
      # may be cut; the requirements part never changes.
      t.integer :cv_line_start, null: false
      t.integer :cv_line_end, null: false
      # SHA-256 of the rubric sent and of the CV text it was prepared from. A release whose digests
      # no longer match the job's rubric or the application's CV text is outdated and never sent.
      t.string :rubric_digest, null: false
      t.string :source_sha256, null: false
      # Category keys from Screening::ResidualCheck.findings on the CV part (never a value).
      t.string :residual_categories, array: true, null: false, default: []
      # A cut: the version this one replaces, who cut, which payload lines, and the SHA-256 of the
      # removed lines (the text itself stays in the superseded row; it is not copied again).
      t.references :supersedes, foreign_key: { to_table: :ai_releases }, index: { unique: true }
      t.references :cut_by, foreign_key: { to_table: :users }
      t.integer :cut_line_numbers, array: true, null: false, default: []
      t.string :cut_sha256
      t.datetime :created_at, null: false
    end
    add_index :ai_releases, %i[participation_id payload_kind id], name: "index_ai_releases_latest"
    add_check_constraint :ai_releases, "payload_kind IN (#{KINDS.map { |k| "'#{k}'" }.join(',')})",
                         name: "ai_releases_payload_kind"
    add_check_constraint :ai_releases, "payload_sha256 = encode(sha256(convert_to(payload_text, 'UTF8')), 'hex')",
                         name: "ai_releases_digest_matches_text"
    add_check_constraint :ai_releases, "cv_line_start >= 0 AND cv_line_end >= cv_line_start - 1",
                         name: "ai_releases_cv_lines"
    add_check_constraint :ai_releases,
                         "(supersedes_id IS NULL) = (cut_by_id IS NULL) AND (supersedes_id IS NULL) = (cut_sha256 IS NULL) " \
                         "AND (supersedes_id IS NULL OR cardinality(cut_line_numbers) > 0)",
                         name: "ai_releases_cut_complete"

    create_table :ai_release_actions do |t|
      t.references :ai_release, null: false, foreign_key: true, index: { unique: true }
      t.string :action, null: false
      t.references :actor, null: false, foreign_key: { to_table: :users }
      # The digest the reviewer saw and released; must equal the version's own.
      t.string :payload_sha256
      # "Saya sudah memeriksa teks ini dan tidak ada data pribadi yang terlihat".
      t.boolean :checked, null: false, default: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_check_constraint :ai_release_actions, "action IN ('released','declined')", name: "ai_release_actions_action"
    add_check_constraint :ai_release_actions, "action <> 'released' OR (checked AND payload_sha256 IS NOT NULL)",
                         name: "ai_release_actions_release_checked"
    add_check_constraint :ai_release_actions, "action <> 'declined' OR length(btrim(coalesce(note, ''))) > 0",
                         name: "ai_release_actions_decline_has_note"

    add_reference :screening_results, :ai_release, foreign_key: true, index: { unique: true }

    remove_check_constraint :participations, name: "participations_screening_state"
    add_check_constraint :participations,
                         "screening_state IS NULL OR screening_state IN " \
                         "('queued','done','screening_failed','cv_unreadable','awaiting_release','not_sent')",
                         name: "participations_screening_state"

    %w[ai_releases ai_release_actions].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
        CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();
      SQL
    end

    execute <<~SQL
      CREATE FUNCTION ai_release_person_allowed(person bigint, release_job bigint) RETURNS boolean
        LANGUAGE sql STABLE AS $$
          SELECT EXISTS (SELECT 1 FROM users WHERE id = person AND role = 'reviewer')
             AND NOT EXISTS (SELECT 1 FROM jobs WHERE id = release_job AND consultant_id = person)
        $$;

      CREATE FUNCTION enforce_ai_release_cut() RETURNS trigger
        LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.supersedes_id IS NOT NULL THEN
          IF NOT ai_release_person_allowed(NEW.cut_by_id, NEW.job_id) THEN
            RAISE EXCEPTION 'ai release cut refused: user % is not a reviewer or is the job''s consultant', NEW.cut_by_id
              USING ERRCODE = 'check_violation';
          END IF;
          IF EXISTS (SELECT 1 FROM ai_release_actions WHERE ai_release_id = NEW.supersedes_id) THEN
            RAISE EXCEPTION 'ai release cut refused: version % is already decided', NEW.supersedes_id
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER ai_releases_cut_by_reviewer BEFORE INSERT ON ai_releases
        FOR EACH ROW EXECUTE FUNCTION enforce_ai_release_cut();

      CREATE FUNCTION enforce_ai_release_action() RETURNS trigger
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
      CREATE TRIGGER ai_release_actions_guard BEFORE INSERT ON ai_release_actions
        FOR EACH ROW EXECUTE FUNCTION enforce_ai_release_action();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS ai_release_actions_guard ON ai_release_actions"
    execute "DROP TRIGGER IF EXISTS ai_releases_cut_by_reviewer ON ai_releases"
    execute "DROP FUNCTION IF EXISTS enforce_ai_release_action()"
    execute "DROP FUNCTION IF EXISTS enforce_ai_release_cut()"
    execute "DROP FUNCTION IF EXISTS ai_release_person_allowed(bigint, bigint)"
    remove_check_constraint :participations, name: "participations_screening_state"
    add_check_constraint :participations,
                         "screening_state IS NULL OR screening_state IN ('queued','done','screening_failed','cv_unreadable')",
                         name: "participations_screening_state"
    remove_reference :screening_results, :ai_release, foreign_key: true
    drop_table :ai_release_actions
    drop_table :ai_releases
  end
end
