# Feature 07 follow-up to 20261010000014: the model behind test_cases is TechnicalTestCase (the bare
# name TestCase collides with ActionView::TestCase inside views), so ActiveStorage writes
# record_type 'TechnicalTestCase'. The two guards that read the attachment table are re-created
# with that name; nothing else changes. Additive: CREATE OR REPLACE of two feature-07 functions.
class RenameTestCaseRecordType < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION enforce_test_case_file_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE target active_storage_attachments%ROWTYPE;
      BEGIN
        target := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
        IF target.record_type = 'TechnicalTestCase' AND test_case_is_final(target.record_id) THEN
          RAISE EXCEPTION 'active_storage_attachments: the case file of a started or approved test version never changes'
            USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$;
    SQL
    function = select_value("SELECT pg_get_functiondef('enforce_test_case_freeze'::regproc)")
    raise "enforce_test_case_freeze() not found" if function.blank?

    execute(function.sub("att.record_type = 'TestCase'", "att.record_type = 'TechnicalTestCase'"))
    unless select_value("SELECT pg_get_functiondef('enforce_test_case_freeze'::regproc)").include?("'TechnicalTestCase'")
      raise "enforce_test_case_freeze() was not updated"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
