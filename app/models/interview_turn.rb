# One question and its answer. The answer is written once; afterwards only CandidateErasure may clear the
# texts (update_all, which skips this guard on purpose).
class InterviewTurn < ApplicationRecord
  belongs_to :interview

  validates :position, numericality: { only_integer: true, in: 1..Interview::MAX_TURNS }
  validates :question, presence: true, on: :create

  before_update { raise ActiveRecord::ReadOnlyRecord, "an interview answer is written once" if answered_at_in_database.present? }
end
