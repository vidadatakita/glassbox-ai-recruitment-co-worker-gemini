# A person's decision on one AiRelease version (D51 B): "released" (Send to Gemini, with the
# checkbox "I have checked this text and no personal data is visible" and the digest
# of the exact text released) or "declined" (Not sent — decide manually, with a note).
# Append-only, one per version; the database refuses an actor who is not a reviewer or who is the
# job's consultant, a digest that is not the version's own, a version that is not the latest, and
# a release of a version with residual-check findings.
class AiReleaseAction < ApplicationRecord
  include AppendOnly

  ACTIONS = { "released" => "Sent to Gemini", "declined" => "Not sent, decided manually" }.freeze

  belongs_to :ai_release
  belongs_to :actor, class_name: "User"

  validates :action, inclusion: { in: ACTIONS.keys }
  validates :note, presence: true, if: -> { action == "declined" }
  validates :checked, acceptance: { accept: true }, if: -> { action == "released" }
  validates :payload_sha256, presence: true, if: -> { action == "released" }
end
