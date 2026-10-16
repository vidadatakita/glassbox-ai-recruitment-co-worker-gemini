# Feature 08 (D61, D62 h3/h4; E21 "a person decides"): the reviewer's confirmation of the Analisa
# label of one S1 result. Append-only; the newest row per participation is the label in force.
# Over-qualified needs a note and a last-role Golongan >= job Golongan + 2 (database CHECK
# label_confirmations_over_qualified_rule); the reviewer is never the job's consultant (trigger).
class ScreeningLabelConfirmation < ApplicationRecord
  include AppendOnly

  belongs_to :participation
  belongs_to :screening_result
  belongs_to :reviewer, class_name: "User"

  validates :label, inclusion: { in: ScreeningReport::Labels::ORDER }

  def self.current_for(participation_ids)
    where(id: unscoped.where(participation_id: participation_ids).group(:participation_id).select("MAX(id)"))
  end
end
