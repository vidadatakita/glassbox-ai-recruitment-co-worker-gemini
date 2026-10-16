# Database guards for the findings of the Plan 1 test-engine run, 2026-10-10
# (docs/features/01-scoring-core.md §7). Each guard repeats in PostgreSQL a rule the models
# already enforce, because a model is bypassed by update_columns, update_all, raw SQL or a
# console; the database is not.
class HardenScoringRecords < ActiveRecord::Migration[8.1]
  APPEND_ONLY = %w[score_entries decisions stage_changes].freeze

  def up
    # F-01/F-02/F-03/F-04: a stage moves draft -> open -> closed only; opened_at is set once; and
    # once opened, weight and threshold change only together with the StageChange row (old -> new)
    # that the same transaction named in the transaction-local setting glassbox.stage_change_id
    # (Stages::ChangeThreshold sets it with set_config(..., true)). A first design compared xmin
    # with txid_current(); it failed because Rails saves inside savepoints, whose rows carry a
    # subtransaction id (2026-10-10 run). The setting ends with the transaction, so an older
    # StageChange cannot be reused by a later edit unless that transaction names it again.
    add_check_constraint :stages, "status = 'draft' OR opened_at IS NOT NULL", name: "stages_opened_at_when_open"
    execute <<~SQL
      CREATE FUNCTION enforce_stage_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.opened_at IS NOT NULL AND NEW.opened_at IS DISTINCT FROM OLD.opened_at THEN
          RAISE EXCEPTION 'stages: opened_at cannot change once set' USING ERRCODE = 'restrict_violation';
        END IF;
        IF NEW.status <> OLD.status AND NOT (
             (OLD.status = 'draft' AND NEW.status = 'open') OR (OLD.status = 'open' AND NEW.status = 'closed')) THEN
          RAISE EXCEPTION 'stages: status cannot move from % to %', OLD.status, NEW.status USING ERRCODE = 'restrict_violation';
        END IF;
        IF OLD.opened_at IS NOT NULL THEN
          IF NEW.threshold <> OLD.threshold AND NOT EXISTS (
               SELECT 1 FROM stage_changes sc
               WHERE sc.stage_id = NEW.id AND sc.field = 'threshold'
                 AND sc.old_value = OLD.threshold AND sc.new_value = NEW.threshold
                 AND sc.id = NULLIF(current_setting('glassbox.stage_change_id', true), '')::bigint) THEN
            RAISE EXCEPTION 'stages: a locked threshold changes only with a StageChange in the same transaction'
              USING ERRCODE = 'restrict_violation';
          END IF;
          IF NEW.weight <> OLD.weight AND NOT EXISTS (
               SELECT 1 FROM stage_changes sc
               WHERE sc.stage_id = NEW.id AND sc.field = 'weight'
                 AND sc.old_value = OLD.weight AND sc.new_value = NEW.weight
                 AND sc.id = NULLIF(current_setting('glassbox.stage_change_id', true), '')::bigint) THEN
            RAISE EXCEPTION 'stages: a locked weight changes only with a StageChange in the same transaction'
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER stages_lifecycle BEFORE UPDATE ON stages
      FOR EACH ROW EXECUTE FUNCTION enforce_stage_lifecycle();
    SQL

    # F-09: one first decision per participation. Later decisions all name the row they replace,
    # so with this index a participation has exactly one chain, hence one current decision.
    # (Score entries are excluded on purpose: each interviewer starts their own first entry.)
    add_index :decisions, :participation_id, unique: true, where: "supersedes_id IS NULL",
              name: "decisions_one_first_decision"

    # F-10: a row may supersede only a row of the same participation; otherwise a correction on
    # one candidate silently removes another candidate's score or decision from "current".
    execute <<~SQL
      CREATE FUNCTION enforce_same_participation_supersede() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE target_participation bigint;
      BEGIN
        IF NEW.supersedes_id IS NULL THEN RETURN NEW; END IF;
        EXECUTE format('SELECT participation_id FROM %I WHERE id = $1', TG_TABLE_NAME)
          INTO target_participation USING NEW.supersedes_id;
        IF target_participation IS DISTINCT FROM NEW.participation_id THEN
          RAISE EXCEPTION '%: a row can supersede only a row of the same participation', TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER score_entries_same_participation BEFORE INSERT ON score_entries
      FOR EACH ROW EXECUTE FUNCTION enforce_same_participation_supersede();
      CREATE TRIGGER decisions_same_participation BEFORE INSERT ON decisions
      FOR EACH ROW EXECUTE FUNCTION enforce_same_participation_supersede();
    SQL

    # F-11: row triggers do not fire on TRUNCATE; a statement trigger does.
    execute <<~SQL
      CREATE FUNCTION forbid_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only: TRUNCATE refused', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
      END;
      $$;
    SQL
    APPEND_ONLY.each do |table|
      execute "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
    end

    # F-16: a manual override needs a real note, not an empty string.
    remove_check_constraint :decisions, name: "decisions_manual_has_reason_and_actor"
    add_check_constraint :decisions,
      "basis <> 'manual' OR (length(btrim(coalesce(note, ''))) > 0 AND decided_by_id IS NOT NULL)",
      name: "decisions_manual_has_reason_and_actor"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
