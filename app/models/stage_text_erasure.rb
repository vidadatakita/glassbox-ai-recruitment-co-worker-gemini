# The logged erasure of one AI Builder Cup D63 text record (migration 20261012210000): written first,
# it lets the database blank that record's free-text columns and nothing else. Append-only.
class StageTextErasure < ApplicationRecord
  # A note that a CHECK requires (a Tidak Lanjut, a salary outside the band) cannot become NULL.
  MARKER = "[dihapus]".freeze

  # record_type => [model, { column => erased value }]; the same list as the migration's triggers.
  TEXTS = {
    "stage_recommendations" => ["StageRecommendation", { summary: nil, reasons: {}, problem: nil }],
    "salary_recommendations" => ["SalaryRecommendation", { summary: nil, factors: [], problem: nil }],
    "progression_choices" => ["ProgressionChoice", { note: MARKER }],
    "salary_agreements" => ["SalaryAgreement", { note: MARKER }],
    "score_entries" => ["ScoreEntry", { note: nil }]
  }.freeze

  belongs_to :job_application
  belongs_to :actor, class_name: "User", optional: true
end
