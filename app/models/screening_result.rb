# One AI judgement of one CV (feature 06; blueprint §4.1 steps 4-6, 9). Append-only: a new
# screening of the same participation (after a rubric change, or a retry by staff) is a NEW row;
# the current result is the participation's latest. The database refuses UPDATE and DELETE.
class ScreeningResult < ApplicationRecord
  include AppendOnly

  belongs_to :participation
  delegate :job, to: :participation # the record's company is its job's (BaseController#org_find)
  belongs_to :score_entry, optional: true
  # Feature 09 (D51 B): the released payload this answer came from (nil for results made before
  # the release gate existed).
  belongs_to :ai_release, optional: true
  # Feature 09 (F09-04): set once the candidate text of this result was erased.
  has_one :screening_result_erasure, dependent: :restrict_with_exception
  has_one :screening_review, dependent: :restrict_with_exception

  validates :rubric_digest, :model_id, :prompt_version, presence: true
  validates :score, numericality: { in: 0..100 }

  # The participation's newest result.
  def self.current_for(participation_ids)
    where(id: unscoped.where(participation_id: participation_ids).group(:participation_id).select("MAX(id)"))
  end

  def stale?(rubric_digest) = self.rubric_digest != rubric_digest

  # [{ "requirement_id", "tier", "text", "judgement", "quote", "verified" }, ...] in rubric order.
  def criteria = judgements.to_a

  def unverified? = unverified_count.positive?
end
