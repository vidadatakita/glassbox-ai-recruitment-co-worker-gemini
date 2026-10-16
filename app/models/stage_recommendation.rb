# AI Builder Cup step 06: the AI's Lanjut / Tidak Lanjut for one stage participation, with reasons
# (Progression::Recommend). Advisory only: never a score, never a Decision; the HR PIC's
# ProgressionChoice moves the candidate. A newer row for the same participation replaces it on
# screen; a choice names the row it was made on (a stale one is refused).
class StageRecommendation < ApplicationRecord
  include AppendOnly

  ADVICE = { "lanjut" => "Continue", "tidak_lanjut" => "Do not continue" }.freeze

  belongs_to :participation
  belongs_to :requested_by, class_name: "User"

  def self.latest_for(participation) = where(participation:).order(:id).last

  def ready? = status == "ready"
  def advice_label = ADVICE[advice]
  def list(key) = Array(reasons[key])
end
