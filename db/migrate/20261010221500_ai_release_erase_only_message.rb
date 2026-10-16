# Feature 09, test engine run 1 follow-up: the erase-only trigger (migration 20261010221000) refused
# every non-erasing UPDATE, but with its own wording. Code and tests that relied on the append-only
# message ("ai_releases is append-only: UPDATE refused") must keep matching it, so the refusal now
# starts with that sentence. Behaviour unchanged: only setting payload_text to NULL is allowed.
class AiReleaseEraseOnlyMessage < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION ai_releases_erase_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
      DECLARE
        app job_applications%ROWTYPE;
        basis text;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'ai_releases is append-only: DELETE refused' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.payload_text IS NOT NULL AND NEW.payload_text NOT IN ('', '[DIHAPUS — retensi]') THEN
          RAISE EXCEPTION 'ai_releases is append-only: UPDATE refused (the only change allowed is erasing payload_text)'
            USING ERRCODE = 'restrict_violation';
        END IF;
        NEW.payload_text := NULL;
        NEW.payload_sha256 := OLD.payload_sha256;
        IF (to_jsonb(NEW) - 'payload_text') IS DISTINCT FROM (to_jsonb(OLD) - 'payload_text') THEN
          RAISE EXCEPTION 'ai_releases is append-only: UPDATE refused (only payload_text may be erased)'
            USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.payload_text IS NULL THEN
          RETURN NEW;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM ai_release_erasures WHERE ai_release_id = OLD.id) THEN
          SELECT ja.* INTO app FROM job_applications ja JOIN participations p ON p.job_application_id = ja.id
            WHERE p.id = OLD.participation_id;
          IF app.consent_withdrawn_at IS NOT NULL THEN
            basis := 'consent_withdrawn';
          ELSIF app.consent_at IS NULL OR app.status = 'no_consent' THEN
            basis := 'no_consent';
          ELSE
            RAISE EXCEPTION 'ai_releases is append-only: UPDATE refused (erasing release % needs an ai_release_erasures row or withdrawn consent)', OLD.id
              USING ERRCODE = 'restrict_violation';
          END IF;
          INSERT INTO ai_release_erasures (ai_release_id, actor_id, reason, note, created_at)
            VALUES (OLD.id, NULL, basis, 'Dicatat oleh basis data saat teks dihapus', now());
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
