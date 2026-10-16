# D49 (5) "every change recorded": who changed which part of a job's brief, in which role, when,
# and the before/after of each changed field. Append-only (trigger job_brief_changes_append_only).
class JobBriefChange < ApplicationRecord
  include AppendOnly

  STEP_LABELS = {
    "1" => "Position & level", "2" => "Activities & 90-day target", "3" => "Requirements & compensation",
    "4" => "Package & stages", "5" => "Technical test", "ad" => "Job ad", "complete" => "Brief completed"
  }.freeze

  belongs_to :job
  belongs_to :actor, class_name: "User"

  validates :step, inclusion: { in: STEP_LABELS.keys }
  validates :actor_role, presence: true
end
