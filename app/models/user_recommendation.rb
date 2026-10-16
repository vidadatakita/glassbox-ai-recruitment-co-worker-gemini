# Feature 08, "Rekomendasi User" (SPEC §1; D62 h6): the hiring manager's pick for one application,
# entered by the HR PIC naming the manager (T1 has no hiring-manager role). Information only: it
# never writes a Decision and never moves a candidate (D64 C1: only a named person's progression
# choice does). Append-only; the newest row per application is shown.
class UserRecommendation < ApplicationRecord
  include AppendOnly

  PICKS = { "lanjut" => ["Continue", "success"], "tidak_lanjut" => ["Do not continue", "danger"] }.freeze

  belongs_to :job_application
  belongs_to :entered_by, class_name: "User"

  validates :pick, inclusion: { in: PICKS.keys }
  validates :user_name, presence: true

  def self.current_for(application_ids)
    where(id: unscoped.where(job_application_id: application_ids).group(:job_application_id).select("MAX(id)"))
  end
end
