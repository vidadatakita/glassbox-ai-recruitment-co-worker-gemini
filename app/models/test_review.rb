# A reviewer's rubric scoring of one technical-test answer (D60 slice 5; plan §c "Scoring (T1)").
# Append-only, one per participation, linked to the ScoreEntry and the Decision it produced. The
# database refuses a reviewer who is not a reviewer or who is the job's consultant, a review of a
# participation with no sent answer, and any update or delete (trigger
# test_reviews_reviewer_not_consultant).
class TestReview < ApplicationRecord
  belongs_to :participation
  belongs_to :test_attempt
  belongs_to :reviewer, class_name: "User"
  belongs_to :score_entry
  belongs_to :decision

  def readonly? = persisted?
end
