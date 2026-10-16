# "Tanya Data": every question asked, which read function answered it with which arguments, and the
# answer shown, for audit. Append-only. The data itself is never stored here.
class CreateDataQuestions < ActiveRecord::Migration[8.1]
  def up
    create_table :data_questions do |t|
      t.references :user, null: false, foreign_key: true
      t.text :question, null: false
      t.string :status, null: false
      t.string :tool
      t.jsonb :args, null: false, default: {}
      t.text :answer
      t.string :model_id
      t.datetime :created_at, null: false
    end
    add_check_constraint :data_questions, "status IN ('answered', 'refused', 'out_of_scope', 'failed')", name: "data_questions_status"
    execute "CREATE TRIGGER data_questions_append_only BEFORE DELETE OR UPDATE ON data_questions FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
    execute "CREATE TRIGGER data_questions_no_truncate BEFORE TRUNCATE ON data_questions FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
  end

  def down
    drop_table :data_questions
  end
end
