class StageChange < ApplicationRecord
  include AppendOnly

  belongs_to :stage

  validates :field, inclusion: { in: %w[weight threshold] }
  validates :reason, :changed_by_id, :changed_at, presence: true
end
