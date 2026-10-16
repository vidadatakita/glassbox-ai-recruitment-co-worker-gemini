# One manual open, close or reopen of a job's portal, with who, why and the limits set
# (BP §3.6 A). Append-only; the window's state is derived by ApplicationWindow.
class ApplicationWindowEvent < ApplicationRecord
  include AppendOnly

  ACTIONS = %w[open close reopen].freeze

  belongs_to :job

  validates :action, inclusion: { in: ACTIONS }
  validates :actor_id, :actor_role, presence: true
  validates :reason, presence: true, if: -> { action == "reopen" }
  validates :quota, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
end
