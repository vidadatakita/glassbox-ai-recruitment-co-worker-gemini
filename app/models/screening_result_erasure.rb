# Why and when one ScreeningResult's candidate text was erased (feature 09, F09-04; UU 27/2022 Pasal
# 40, D16, D32). Erased: every judgements[].quote, the report facts, narratives and label_reason.
# Kept: scores, judgements, verification flags, label proposal, model, who and when (anonymous
# statistics, blueprint §4.2). Who: a user, or NULL for the system (retention task) or the
# candidate's own withdrawal. Append-only; the database lets a screening_results row change ONLY
# after this row exists, and only by that exact blanking (trigger screening_results_erase_only).
# Same shape as AiReleaseErasure and feature 11's RetentionBlanking.
class ScreeningResultErasure < ApplicationRecord
  include AppendOnly

  belongs_to :screening_result
  belongs_to :actor, class_name: "User", optional: true

  validates :reason, inclusion: { in: AiReleaseErasure::REASONS.keys }
end
