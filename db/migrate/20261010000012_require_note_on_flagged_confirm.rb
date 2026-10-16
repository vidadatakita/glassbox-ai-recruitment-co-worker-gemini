# Feature 06, test engine run 4 (F-30): a reviewer's CONFIRM of a result whose AI evidence could
# not be trusted (reason "unverified" or "protected_attribute") is the reviewer's own judgement, so
# it needs a note. Screening::Review already refuses it; this CHECK makes the database refuse it
# too, for any path that bypasses the service. Additive: a new constraint (no existing row breaks:
# the service never wrote such a row).
class RequireNoteOnFlaggedConfirm < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :screening_reviews,
                         "verdict <> 'confirm' OR reason NOT IN ('unverified','protected_attribute') OR length(btrim(coalesce(note, ''))) > 0",
                         name: "screening_reviews_flagged_confirm_has_note"
  end
end
