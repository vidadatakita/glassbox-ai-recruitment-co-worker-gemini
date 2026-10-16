# One requirement line (blueprint §2.1 Requirement [P3]), checkable from a CV: the tier, the text,
# and the evidence a CV would show. Only "sebaiknya" lines carry a weight (the sebaiknya weights
# sum to 100, checked by Briefs::BriefCheck). A "wajib" line may carry the knockout question the
# Lamar page asks (P8, rule 16).
class Requirement < ApplicationRecord
  TIERS = { "wajib" => "Must-have", "sebaiknya" => "Should-have", "nilai_tambah" => "Nice-to-have" }.freeze

  belongs_to :job
  # Removing a requirement only UNLINKS its question: the question's id is the key of every Lamar
  # answer, so Briefs::SaveStep#sync_knockouts re-links it (or deletes it, only while no
  # application exists). :destroy here was test-engine finding F-03.
  has_one :knockout_question, dependent: :nullify

  validates :tier, inclusion: { in: TIERS.keys }
  validates :text, :cv_evidence, :position, presence: true
  validates :weight, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validate :weight_only_on_sebaiknya

  private

  def weight_only_on_sebaiknya
    errors.add(:weight, "is only for a should-have requirement") if weight && tier != "sebaiknya"
  end
end
