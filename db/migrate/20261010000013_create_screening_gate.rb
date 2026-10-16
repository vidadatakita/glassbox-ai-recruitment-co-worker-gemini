# D60 slice 1 (plan docs/plans/2026-10-10-online-test-in-apply-flow.md §a, option A1): S1 (Seleksi
# CV) and S2 (Tes teknis) stay two stages, each with its own score source, threshold, weight and
# append-only rows, but on a package that runs both (packages 3 and up) they form ONE gate,
# "Seleksi CV dan Tes Teknis". This migration is additive: one nullable column, new functions and
# triggers. It does not touch enforce_stage_lifecycle(), the Decider or any existing CHECK.
#
# Guards, each repeating in PostgreSQL a rule the services enforce (a model is bypassed by
# update_columns, update_all, raw SQL or a console; the database is not):
#   1. stages.gate is 'screening' or NULL, and only on S1/S2; one S1 and one S2 per job and gate.
#   2. The gate of a stage cannot change once the stage has left draft.
#   3. DEFERRED constraint trigger: at commit, every member of a gate has the same status, and a
#      gate that has left draft has exactly its two members (S1 and S2). So the two open together
#      and close together; closing one alone is refused at commit. It is deferred because the two
#      rows are updated one after the other in the same transaction; an immediate row check would
#      refuse the first update of a legitimate pair. Gates::Open / Gates::Close force the check at
#      the end of their own transaction (SET CONSTRAINTS ... IMMEDIATE), so a violation surfaces in
#      the service call, not later at an unrelated commit.
#   4. A decision with reason 'gate_eliminated' is a rule elimination (CHECK), written only on a
#      gated S2 participation with no score, whose S1 partner's CURRENT decision is eliminate.
#   5. No score entry on an S2 participation whose current decision is 'gate_eliminated' ("never
#      queued for scoring", plan §a.1).
#
# decisions.reason_code has NO CHECK listing its values (feature 01 left it free text, and the
# engine's own tests write codes such as "o" and "x"), so there is no list to widen; adding a full
# list now would refuse rows other features and the engine write. Only the new value is constrained.
class CreateScreeningGate < ActiveRecord::Migration[8.1]
  def up
    add_column :stages, :gate, :string
    add_check_constraint :stages, "gate IS NULL OR (gate = 'screening' AND code IN ('S1','S2'))", name: "stages_gate"
    add_index :stages, %i[job_id gate code], unique: true, where: "gate IS NOT NULL", name: "stages_one_member_per_gate_code"

    execute <<~SQL
      CREATE FUNCTION enforce_stage_gate_fixed() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.gate IS DISTINCT FROM OLD.gate AND OLD.status <> 'draft' THEN
          RAISE EXCEPTION 'stages: the gate of a stage cannot change once it has opened' USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER stages_gate_fixed BEFORE UPDATE ON stages
      FOR EACH ROW EXECUTE FUNCTION enforce_stage_gate_fixed();

      CREATE FUNCTION enforce_gate_status_together() RETURNS trigger LANGUAGE plpgsql AS $$
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
      CREATE CONSTRAINT TRIGGER stages_gate_status_together AFTER INSERT OR UPDATE ON stages
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION enforce_gate_status_together();
    SQL

    add_check_constraint :decisions, "reason_code <> 'gate_eliminated' OR (basis = 'rule' AND outcome = 'eliminate')",
                         name: "decisions_gate_eliminated_is_rule"
    execute <<~SQL
      CREATE FUNCTION enforce_gate_eliminated() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE s2 stages%ROWTYPE; application_id bigint;
      BEGIN
        IF NEW.reason_code <> 'gate_eliminated' THEN RETURN NEW; END IF;
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
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER decisions_gate_eliminated BEFORE INSERT ON decisions
      FOR EACH ROW EXECUTE FUNCTION enforce_gate_eliminated();

      CREATE FUNCTION forbid_score_after_gate_elimination() RETURNS trigger LANGUAGE plpgsql AS $$
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
      CREATE TRIGGER score_entries_not_after_gate_elimination BEFORE INSERT ON score_entries
      FOR EACH ROW EXECUTE FUNCTION forbid_score_after_gate_elimination();
    SQL

    # Backfill: jobs whose COMPLETE brief runs package 3+ and whose S1 and S2 are both still in the
    # same status get the gate (on development that is the six D49 demo jobs, all draft). A job whose
    # S1 and S2 already differ (opened one by one before this rule) is left without a gate and listed
    # in the feature record, because setting it would break the "together" rule at this commit.
    execute <<~SQL
      UPDATE stages st SET gate = 'screening'
      FROM jobs j
      WHERE st.job_id = j.id AND st.code IN ('S1','S2') AND j.brief_status = 'complete' AND j.package >= 3
        AND (SELECT count(DISTINCT s.status) FROM stages s WHERE s.job_id = j.id AND s.code IN ('S1','S2')) = 1
        AND (SELECT count(*) FROM stages s WHERE s.job_id = j.id AND s.code IN ('S1','S2')) = 2;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
