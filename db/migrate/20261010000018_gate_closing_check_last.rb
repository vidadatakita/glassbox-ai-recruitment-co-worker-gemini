# Follow-up to 20261010000016/17 (F-06): the "only while the gate closes" refusal is now the LAST
# check of enforce_gate_eliminated(), so a row that is wrong in substance (on S1, after a score,
# without a current S1 elimination) is refused with that reason, not with the timing one.
# Additive: CREATE OR REPLACE of one feature-07 function, written out in full; same rules as 16+17.
class GateClosingCheckLast < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_gate_eliminated() RETURNS trigger LANGUAGE plpgsql AS $$
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
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
