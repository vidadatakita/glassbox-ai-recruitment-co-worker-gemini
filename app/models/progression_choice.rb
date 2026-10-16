# AI Builder Cup step 06: the HR PIC's choice for one stage participation (for the S1+S2 gate, on
# the S1 row): Lanjut, Rekomendasi AI (follows the named recommendation), or Tidak Lanjut. This
# record moves the candidate (Progression::Choose); the database allows only the HR PIC, one choice
# per participation, and a note on every Tidak Lanjut.
class ProgressionChoice < ApplicationRecord
  include AppendOnly

  CHOICES = { "lanjut" => "Continue", "ikut_ai" => "Follow AI advice", "tidak_lanjut" => "Do not continue" }.freeze

  belongs_to :participation
  belongs_to :stage_recommendation, optional: true
  belongs_to :actor, class_name: "User"

  def label = choice == "ikut_ai" ? "Follow AI advice (#{StageRecommendation::ADVICE[direction]})" : CHOICES[choice]
end
