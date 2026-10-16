# Why and when one AiRelease's text was erased (feature 09, F09-03; UU 27/2022 Pasal 40, D16, D32).
# Who: a user, or NULL for the system (retention task) or the candidate's own consent withdrawal.
# Append-only. The database lets an ai_releases row change ONLY by setting payload_text to NULL, and
# only when this row exists (or consent is withdrawn / was never given, in which case the trigger
# writes this row itself). Same shape as feature 11's RetentionBlanking: one per record.
class AiReleaseErasure < ApplicationRecord
  include AppendOnly

  REASONS = { "retention_expired" => "Retention period ended", "consent_withdrawn" => "Consent withdrawn",
              "no_consent" => "No consent" }.freeze

  belongs_to :ai_release
  belongs_to :actor, class_name: "User", optional: true

  validates :reason, inclusion: { in: REASONS.keys }
end
