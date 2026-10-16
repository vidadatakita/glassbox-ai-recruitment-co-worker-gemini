# Feature 09, test engine run 2 (F09-04..06). Additive: one new append-only table and two trigger
# functions replaced by stricter ones. One shape for one legal operation (UU 27/2022 Pasal 40, D16,
# D32), the same as feature 11's retention_blankings / allow_retention_blank_only:
#   a service FIRST writes an erasure row (who, why, when), THEN a single UPDATE sets the personal
#   text columns to NULL; the trigger permits exactly that and refuses everything else.
#
# F09-05  ai_releases_erase_only() kept a changed digest silently (NEW.payload_sha256 := OLD...).
#         It now REFUSES any change other than payload_text -> NULL ("" is still normalised to NULL).
# F09-06  ai_releases_erase_only() wrote its own erasure row (actor NULL) when consent was withdrawn.
#         Rejected by the engine (one shape): it now REFUSES an erase without a pre-recorded
#         ai_release_erasures row, whatever the application's consent state.
# F09-04  screening_results held the candidate's CV quotes (judgements[].quote, the feature-08 report
#         facts and narratives, label_reason) with no erasure path. New screening_result_erasures
#         (same columns as ai_release_erasures) and screening_results_erase_only(): with an erasure
#         row, an UPDATE may set last_position, education, recent_experience, narratives and
#         label_reason to NULL and every judgements[].quote to null - all of them, exactly, in one
#         statement - and nothing else. Scores, judgements, verification flags, label_proposal,
#         digests, who and when stay (anonymous statistics, blueprint §4.2). The trigger keeps the
#         name screening_results_append_only (tests and code refer to it), and refusals start with
#         "screening_results is append-only: UPDATE refused".
class ErasureOneShape < ActiveRecord::Migration[8.1]
  def up
    create_table :screening_result_erasures do |t|
      t.references :screening_result, null: false, foreign_key: true, index: { unique: true }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :reason, null: false
      t.text :note
      t.datetime :created_at, null: false
    end
    add_check_constraint :screening_result_erasures, "reason IN ('retention_expired','consent_withdrawn','no_consent')",
                         name: "screening_result_erasures_reason"

    execute <<~SQL
      CREATE TRIGGER screening_result_erasures_append_only BEFORE UPDATE OR DELETE ON screening_result_erasures
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      CREATE TRIGGER screening_result_erasures_no_truncate BEFORE TRUNCATE ON screening_result_erasures
        FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

      CREATE OR REPLACE FUNCTION ai_releases_erase_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
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

      CREATE FUNCTION screening_results_erase_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
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

      -- judgements with every element's "quote" set to null, order kept. Used by the trigger AND by
      -- the erasure service, so the two can never disagree on the target value.
      CREATE FUNCTION screening_judgements_without_quotes(j jsonb) RETURNS jsonb
        LANGUAGE sql IMMUTABLE AS $$
          SELECT coalesce(jsonb_agg(CASE WHEN jsonb_typeof(e) = 'object' THEN e || '{"quote": null}'::jsonb ELSE e END ORDER BY o), '[]'::jsonb)
            FROM jsonb_array_elements(j) WITH ORDINALITY AS t(e, o)
        $$;

      DROP TRIGGER screening_results_append_only ON screening_results;
      CREATE TRIGGER screening_results_append_only BEFORE UPDATE OR DELETE ON screening_results
        FOR EACH ROW EXECUTE FUNCTION screening_results_erase_only();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "erased texts cannot be restored; never roll this back on a database with real data"
  end
end
