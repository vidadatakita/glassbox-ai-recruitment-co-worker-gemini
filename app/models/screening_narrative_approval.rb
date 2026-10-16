# Feature 08 (D62 h2): the consultant's approval of the four AI narrative boxes of ONE screening
# result. Until it exists the boxes read "Draf AI". A newer result (re-screening) needs its own
# approval: the approval is keyed to the result, not to the candidate. Append-only, one per result.
class ScreeningNarrativeApproval < ApplicationRecord
  include AppendOnly

  belongs_to :screening_result
  belongs_to :approved_by, class_name: "User"
end
