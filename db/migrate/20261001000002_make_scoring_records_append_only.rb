# Score entries, decisions and stage changes are never edited or deleted (blueprint §2.1,
# expensive failure #4). The models are read-only after insert, but models can be bypassed
# (update_all, delete_all, raw SQL, a console session); this trigger cannot.
#
# Consequence to know: a job with any score or decision can no longer be deleted. That is
# intended - its history is the product's evidence.
class MakeScoringRecordsAppendOnly < ActiveRecord::Migration[8.1]
  TABLES = %w[score_entries decisions stage_changes].freeze

  def up
    execute <<~SQL
      CREATE FUNCTION forbid_update_delete() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END;
      $$;
    SQL
    TABLES.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
      SQL
    end
  end

  def down
    TABLES.each { |table| execute "DROP TRIGGER #{table}_append_only ON #{table};" }
    execute "DROP FUNCTION forbid_update_delete();"
  end
end
