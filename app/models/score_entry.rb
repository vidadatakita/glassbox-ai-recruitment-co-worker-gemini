class ScoreEntry < ApplicationRecord
  include Supersedable

  belongs_to :participation

  validates :value, numericality: { in: 0..100 }
  validates :entered_by_id, :entered_at, presence: true
  validates :correction_reason, presence: true, if: :supersedes_id?
  validate :supersedes_a_current_entry_of_the_same_participation, on: :create
  validate :participant_attended, on: :create

  private

  # Rule 5: a no-show or a withdrawal has no score entry. Without this check a score typed
  # against a no-show would be picked up by current_score and the cumulative (test engine F-08).
  def participant_attended
    return if participation.nil? || participation.attendance == "attended"

    errors.add(:participation, "has attendance #{participation.attendance}; only an attended participation is scored")
  end

  def supersedes_a_current_entry_of_the_same_participation
    return unless supersedes

    errors.add(:supersedes, "belongs to another participation") if supersedes.participation_id != participation_id
    errors.add(:supersedes, "has already been corrected") unless ScoreEntry.current.exists?(supersedes.id)
  end
end
