# One version of a payload that could be sent to the Gemini API, waiting for, or carrying, a
# person's decision (D51 B, feature 09). Reusable across payload kinds: cv_screening now;
# interview_note and stage_recommendation are reserved for D63 and have no sender yet.
#
# Append-only. A reviewer's cut ("Delete ticked lines") is a NEW row that supersedes this one; the
# database refuses UPDATE and DELETE, checks that payload_sha256 = sha256(payload_text), and
# refuses a release or cut by anyone but a reviewer who is not the job's consultant (migration
# CreateAiReleaseGate).
#
# payload_text is EXACTLY the user-message text the API call sends (Screening::AiClient
# .user_content). The release screen shows this text, not a re-render, and the sender sends this
# text after re-checking its digest; it is never rebuilt between review and send.
class AiRelease < ApplicationRecord
  include AppendOnly

  KINDS = { "cv_screening" => "CV screening", "interview_note" => "Interview note",
            "stage_recommendation" => "Stage advice" }.freeze

  belongs_to :participation
  belongs_to :job
  belongs_to :supersedes, class_name: "AiRelease", optional: true
  belongs_to :cut_by, class_name: "User", optional: true
  has_one :action, class_name: "AiReleaseAction", dependent: :restrict_with_exception
  has_one :superseded_by, class_name: "AiRelease", foreign_key: :supersedes_id, dependent: :restrict_with_exception
  has_one :screening_result, dependent: :restrict_with_exception

  validates :payload_kind, inclusion: { in: KINDS.keys }
  has_one :erasure, class_name: "AiReleaseErasure", dependent: :restrict_with_exception

  validates :payload_text, presence: true, on: :create
  validates :payload_sha256, :rubric_digest, :source_sha256, presence: true

  scope :cv_screening, -> { where(payload_kind: "cv_screening") }

  def self.digest(text) = Digest::SHA256.hexdigest(text.to_s.encode("UTF-8"))

  # The newest version for one participation and kind (a cut or a re-preparation is always newer).
  def self.latest_for(participation, kind = "cv_screening")
    where(participation:, payload_kind: kind).order(:id).last
  end

  # Erased (F09-03): payload_text is NULL; the digest and the records stay. An erased version is
  # never shown, cut, released or sent.
  def erased? = payload_text.nil?
  def lines = payload_text.to_s.split("\n", -1)
  def cv_range = (cv_line_start..cv_line_end)
  # The CV part exactly as the model sees it (used for the quote check after the answer).
  def cv_part = lines[cv_range].to_a.join("\n")

  def latest? = !self.class.where(participation_id:, payload_kind:).where("id > ?", id).exists?
  def released? = action&.action == "released"
  def declined? = action&.action == "declined"
  def pending? = action.nil?
  def consumed? = screening_result.present?
  def residual? = residual_categories.any?

  # The text the database holds still hashes to the digest recorded with it.
  def digest_intact? = !erased? && self.class.digest(payload_text) == payload_sha256
end
