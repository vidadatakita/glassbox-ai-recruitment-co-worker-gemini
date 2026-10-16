# AI Builder Cup step 07, Interview 2 (user): the HR PIC invites an interviewer who has no account
# (the hiring manager, D62 h6) to score from a link on a phone. One row per invitation; the link
# itself is a OneTimeLink (purpose "interviewer_score", only the token digest stored). On submit the
# score is a ScoreEntry (append-only), the manager's Lanjut / Tidak lanjut a UserRecommendation.
class CreateInterviewerInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :interviewer_invites do |t|
      t.references :participation, null: false, foreign_key: true
      t.string :interviewer_name, null: false
      t.bigint :issued_by_id, null: false
      t.references :score_entry, foreign_key: true, index: { unique: true }
      t.datetime :submitted_at
      t.timestamps
    end
    add_foreign_key :interviewer_invites, :users, column: :issued_by_id
    add_check_constraint :interviewer_invites, "length(btrim(interviewer_name)) > 0", name: "interviewer_invites_named"
    add_check_constraint :interviewer_invites, "(submitted_at IS NULL) = (score_entry_id IS NULL)", name: "interviewer_invites_submitted_has_score"
  end
end
