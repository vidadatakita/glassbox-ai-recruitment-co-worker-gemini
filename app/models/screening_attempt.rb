# One try of the screening job for one participation, succeeded or failed (blueprint §4.3). The
# trail behind "Screening gagal": which kind of failure, how many tries. Append-only; never holds
# CV text, only a kind ("timeout", "refusal", ...) and a short detail ("HTTP 529", "cyber").
class ScreeningAttempt < ApplicationRecord
  include AppendOnly

  OUTCOMES = %w[succeeded failed cv_unreadable].freeze

  belongs_to :participation

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :attempt, numericality: { only_integer: true, greater_than: 0 }
end
