# Test engine 07 findings F-03, F-06 and F-04 (2026-10-10, docs/features/07-technical-test.md §7).
# Additive: one new trigger on test_cases, one replaced feature-07 function, one new trigger on
# decisions. Nothing from features 01-06 changes.
#
# F-03: the approval checks (approver is HR PIC, rubric weights 100, recorded file) lived in the
#       BEFORE UPDATE trigger only, so a version INSERTED already approved skipped all of them.
#       A version is now always inserted as a draft; approval is a later UPDATE, which is checked.
# F-06: B-1 says gate_eliminated is written when the gate closes, when S1 is final. The database
#       accepted it at any moment. Gates::Close now names the S2 stage it is closing in the
#       transaction-local setting glassbox.gate_closing (the house pattern of glassbox.stage_change_id),
#       and the trigger refuses the row unless that setting names this S2 stage.
# F-04: after the gate closed, an S1 elimination corrected to anything else by a person (D37: on a
#       closed stage only a manual decision, e.g. an upheld objection, E21) left S2 on gate_eliminated,
#       so the candidate's test could never be scored. Every such correction now also writes, in the
#       same statement, a manual S2 decision that supersedes the gate row: outcome "review", reason
#       "gate_reopened_after_s1_correction", by the same person, with a note. It is a trigger so that
#       every path that writes the S1 correction (service, console, raw SQL) gets it. What happens next
#       (a test window for that one candidate) is slices 3-5; recorded as an open item for GlassBox Team.
class HardenGateAndTestVersions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION enforce_test_case_inserted_as_draft() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.approved_at IS NOT NULL OR NEW.approved_by_id IS NOT NULL THEN
          RAISE EXCEPTION 'test_cases: a version is inserted as a draft; HR PIC approves it afterwards'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER test_cases_inserted_as_draft BEFORE INSERT ON test_cases
      FOR EACH ROW EXECUTE FUNCTION enforce_test_case_inserted_as_draft();

      CREATE OR REPLACE FUNCTION enforce_gate_eliminated() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE s2 stages%ROWTYPE; application_id bigint;
      BEGIN
        IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;
        SELECT st.* INTO s2 FROM participations p JOIN stages st ON st.id = p.stage_id WHERE p.id = NEW.participation_id;
        SELECT p.job_application_id INTO application_id FROM participations p WHERE p.id = NEW.participation_id;
        IF s2.gate IS NULL OR s2.code <> 'S2' THEN
          RAISE EXCEPTION 'decisions: gate_eliminated is written only on the S2 stage of a gate' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NULLIF(current_setting('glassbox.gate_closing', true), '') IS DISTINCT FROM s2.id::text THEN
          RAISE EXCEPTION 'decisions: gate_eliminated is written only while the gate closes (Gates::Close)'
            USING ERRCODE = 'restrict_violation';
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
        RETURN NEW;
      END;
      $$;

      CREATE FUNCTION reopen_test_after_s1_correction() RETURNS trigger LANGUAGE plpgsql AS $$
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
      CREATE TRIGGER decisions_reopen_test_after_s1_correction AFTER INSERT ON decisions
      FOR EACH ROW EXECUTE FUNCTION reopen_test_after_s1_correction();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
