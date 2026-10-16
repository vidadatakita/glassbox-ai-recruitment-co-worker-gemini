# Feature 08, test engine 08 run 1 F-02 (LOW): D62 h3 says Over-qualified is "quote-backed". The
# service (ScreeningReport::ConfirmLabel) already refuses it when the last-position quote was not
# found in the CV; the database did not, so a raw insert could record it. This replaces the trigger
# function with a superset: every check of migration 30 is kept word for word, one is added.
# Additive in effect (no existing row is touched; the function only runs on INSERT).
class RequireVerifiedLastPositionForOverQualified < ActiveRecord::Migration[8.1]
  CHECKS = <<~SQL
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
  SQL

  def up
    execute function_sql(<<~SQL)
      IF NEW.label = 'over_qualified' AND NOT EXISTS (
           SELECT 1 FROM screening_results
            WHERE id = NEW.screening_result_id AND (last_position ->> 'verified') = 'true') THEN
        RAISE EXCEPTION 'label confirmation refused: Over-qualified needs a last-position quote found in the CV'
          USING ERRCODE = 'check_violation';
      END IF;
    SQL
  end

  def down
    execute function_sql("")
  end

  private

  def function_sql(extra)
    <<~SQL
      CREATE OR REPLACE FUNCTION enforce_label_confirmation() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE
        actual_golongan integer;
        result_participation bigint;
      BEGIN
        #{CHECKS}
        #{extra}
        RETURN NEW;
      END;
      $$;
    SQL
  end
end
