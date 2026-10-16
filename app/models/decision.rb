class Decision < ApplicationRecord
  include Supersedable

  OUTCOMES = %w[pass eliminate review].freeze
  BASES = %w[threshold manual rule].freeze

  belongs_to :participation

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :basis, inclusion: { in: BASES }
  validates :reason_code, :decided_at, presence: true
  # Rule 4: an override is allowed but never anonymous or unexplained.
  validates :note, :decided_by_id, presence: true, if: -> { basis == "manual" }
  validate :supersedes_the_current_decision, on: :create
  validate :threshold_basis_needs_an_attended_score, on: :create
  validate :stage_state_allows_this_decision, on: :create

  private

  # A threshold decision compares a score with the line, so it exists only for someone who
  # attended and has a current score. Without this, a no-show could be recorded as passed by
  # threshold (test engine F-06, critical) and a scoreless row would make the next threshold
  # change raise for the whole stage (F-15). A manual override stays possible (rule 4).
  def threshold_basis_needs_an_attended_score
    return unless basis == "threshold" && participation

    errors.add(:basis, "threshold needs an attended participation") unless participation.attendance == "attended"
    errors.add(:basis, "threshold needs a current score") if participation.current_score.nil?
  end

  # D37 (2026-10-10): no decision on a draft stage; on a closed stage only a manual decision
  # with a reason, which is how a correction after close is made (the E21 objection path).
  def stage_state_allows_this_decision
    stage = participation&.stage
    return if stage.nil?

    errors.add(:base, "stage is still a draft") if stage.status == "draft"
    errors.add(:basis, "only a manual decision is allowed on a closed stage") if stage.status == "closed" && basis != "manual"
  end

  # One current decision per participation: a new decision must name the one it replaces.
  def supersedes_the_current_decision
    current = Decision.current.where(participation_id:).first
    if current && supersedes_id != current.id
      errors.add(:supersedes, "must be the participation's current decision")
    elsif current.nil? && supersedes_id.present?
      errors.add(:supersedes, "is not a current decision")
    end
  end
end
