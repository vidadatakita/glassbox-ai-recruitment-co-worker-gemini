# The consultant's own pass / eliminate judgement of one CV during calibration (blueprint §4.1
# step 7, D13). Keyed to the rubric digest: after a rubric fix, the CV is judged again. Append-only.
class CalibrationJudgement < ApplicationRecord
  include AppendOnly

  OUTCOMES = { "pass" => "Passed", "eliminate" => "Not passed" }.freeze

  belongs_to :job
  belongs_to :participation
  belongs_to :judged_by, class_name: "User"

  validates :outcome, inclusion: { in: OUTCOMES.keys }
  validates :rubric_digest, presence: true
end
