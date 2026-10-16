# AI Builder Cup step 09, close-out: the AI drafts the rejection notice or the offer letter, the HR
# PIC edits and sends it. One row per AI draft (status "draft") and one per letter sent ("sent",
# with the exact text and the mail delivery). Append-only: what a candidate was told stays on record.
class CreateCandidateLetters < ActiveRecord::Migration[8.1]
  def up
    create_table :candidate_letters do |t|
      t.references :job_application, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :status, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.references :mail_delivery, foreign_key: true
      t.bigint :actor_id, null: false
      t.string :model_id
      t.string :prompt_version
      t.datetime :created_at, null: false
    end
    add_foreign_key :candidate_letters, :users, column: :actor_id
    add_check_constraint :candidate_letters, "kind IN ('rejection', 'offer')", name: "candidate_letters_kind"
    add_check_constraint :candidate_letters, "status IN ('draft', 'sent')", name: "candidate_letters_status"
    add_check_constraint :candidate_letters, "status = 'draft' OR mail_delivery_id IS NOT NULL", name: "candidate_letters_sent_has_delivery"
    execute "CREATE TRIGGER candidate_letters_append_only BEFORE DELETE OR UPDATE ON candidate_letters FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();"
    execute "CREATE TRIGGER candidate_letters_no_truncate BEFORE TRUNCATE ON candidate_letters FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();"
  end

  def down
    drop_table :candidate_letters
  end
end
