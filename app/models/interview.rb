# One AI interview per application (docs/features/05-ai-interview.md). It exists only
# when the switch is on at submit time; Screening::Enqueue holds S1 while it is open (gate :interview_pending).
class Interview < ApplicationRecord
  STATUSES = %w[open finished].freeze
  FINISH_REASONS = %w[completed ended_by_candidate time_up never_started ai_unavailable consent_withdrawn staff_started].freeze
  MAX_TURNS = 5
  MAX_ANSWER = 1000
  TIME_LIMIT = 30.minutes
  START_WINDOW = 48.hours

  belongs_to :job_application
  has_many :turns, -> { order(:position) }, class_name: "InterviewTurn", dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :finish_reason, inclusion: { in: FINISH_REASONS }, allow_nil: true

  delegate :job, to: :job_application

  def open? = status == "open"
  def finished? = status == "finished"

  # The clock runs from the first question shown, never from the page being opened again.
  def due_at = started_at && started_at + TIME_LIMIT

  # Answered and not held: the only turns the AI may read.
  def clean_turns = turns.select { |turn| turn.answered_at && !turn.held }

  def held_count = turns.count(&:held)
end
