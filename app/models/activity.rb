# One activity of the job (blueprint §2.1 Activity [P1]): what the person does, what it produces,
# and its share of working time in whole percent. 5-8 per job, shares summing to 100: checked by
# Briefs::BriefCheck at completion, not here, so a draft can hold a half-typed list.
class Activity < ApplicationRecord
  belongs_to :job

  validates :description, :output, :position, presence: true
  validates :share_percent, numericality: { only_integer: true, in: 0..100 }
end
