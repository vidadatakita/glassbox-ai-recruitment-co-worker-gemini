# A reviewer's confirmation or reversal of one AI result (blueprint §4.1 step 8). Every review
# writes the Decision it stands for (decision_id) in the same transaction (Screening::Review).
# Append-only; the database also refuses a reviewer who is not a reviewer or who is the job's
# consultant (trigger screening_reviews_reviewer_not_consultant).
class ScreeningReview < ApplicationRecord
  include AppendOnly

  VERDICTS = { "confirm" => "Followed AI advice", "reverse" => "Reversed" }.freeze
  REASONS = {
    "elimination" => "AI elimination",
    "sample" => "10% sample of passes",
    "unverified" => "Quote unverified",
    "calibration_disagreement" => "Consultant and AI disagreed in calibration",
    # ADR 0004 line 3: the model saw a protected attribute in the redacted text.
    "protected_attribute" => "The AI saw a protected attribute"
  }.freeze

  belongs_to :participation
  belongs_to :screening_result
  belongs_to :reviewer, class_name: "User"
  belongs_to :decision

  validates :verdict, inclusion: { in: VERDICTS.keys }
  validates :reason, inclusion: { in: REASONS.keys }
  validates :note, presence: true, if: -> { verdict == "reverse" }
end
