# Why and when the texts of one interview were erased (consent withdrawn, retention end, no consent). Written
# by CandidateErasure before the question and answer columns are set to NULL. Append-only.
# Who: a user, or NULL for the system (retention task) or the candidate's own withdrawal.
class InterviewErasure < ApplicationRecord
  include AppendOnly

  belongs_to :interview
  belongs_to :actor, class_name: "User", optional: true

  validates :reason, inclusion: { in: AiReleaseErasure::REASONS.keys }
end
