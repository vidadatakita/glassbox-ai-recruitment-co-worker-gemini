# Second test-engine run on feature 01, 2026-10-10.
# Replaces enforce_stage_lifecycle() with three more database guards:
#   F-19: weight and threshold never change on a CLOSED stage (D37 R2), whatever an in-memory
#         object believed; a stale object in a second tab could otherwise move it.
#   F-20: a stage closes only when every participation has a current decision that is not a
#         review (§3.4), the same rule as Stages::Close, so update_all cannot skip it.
#   F-21: the StageChange named by glassbox.stage_change_id must be the LATEST change of that
#         field for the stage; an older row cannot be replayed to repeat an old move unlogged.
class TightenStageLifecycle < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_stage_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
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
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
