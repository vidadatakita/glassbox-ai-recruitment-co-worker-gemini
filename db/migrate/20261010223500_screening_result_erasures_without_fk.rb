# Feature 09 (F09-04 follow-up). The foreign key screening_result_erasures -> screening_results made
# PostgreSQL refuse TRUNCATE screening_results with "cannot truncate a table referenced in a foreign
# key constraint" BEFORE the append-only TRUNCATE trigger could, so the refusal no longer said why
# (feature-06 engine test "refuse TRUNCATE … by the trigger, not by a foreign key"; feature 08 hit the
# same trap, migration 30). The FK is replaced by an insert trigger that checks the result exists.
# Rows of either table can never be deleted, so the reference cannot dangle.
class ScreeningResultErasuresWithoutFk < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :screening_result_erasures, :screening_results
    execute <<~SQL
      CREATE FUNCTION screening_result_erasures_result_exists() RETURNS trigger
        LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM screening_results WHERE id = NEW.screening_result_id) THEN
          RAISE EXCEPTION 'screening_result_erasures: screening result % does not exist', NEW.screening_result_id
            USING ERRCODE = 'foreign_key_violation';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER screening_result_erasures_result_exists BEFORE INSERT ON screening_result_erasures
        FOR EACH ROW EXECUTE FUNCTION screening_result_erasures_result_exists();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
