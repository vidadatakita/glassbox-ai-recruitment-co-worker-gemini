# One competency of the job (blueprint §2.1 Competency [P4, P17]): its layer from the competence
# lens (§2.3), the ONE stage that assesses it, rating anchors for 1 / 3 / 5 and, for the interview
# stages, the questions. Rule 19: anchors name an action and its result, never personality.
class Competency < ApplicationRecord
  LAYERS = {
    "L1" => "Knowledge", "L2" => "Understanding", "L3" => "Work judgement",
    "L4" => "Work skill", "L5" => "Teaching", "I" => "Integrity"
  }.freeze
  # S1-S5 only. RC (reference check) produces pass / concern with no score (rule 12), so it cannot
  # own a rated competency.
  STAGE_CODES = %w[S1 S2 S3 S4 S5].freeze
  INTERVIEW_STAGES = %w[S3 S5].freeze

  belongs_to :job

  validates :name, :position, presence: true
  validates :layer, inclusion: { in: LAYERS.keys }
  validates :stage_code, inclusion: { in: STAGE_CODES }

  def layer_label = "#{layer} #{LAYERS[layer]}"
end
