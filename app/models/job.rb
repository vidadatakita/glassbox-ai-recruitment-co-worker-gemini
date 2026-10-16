class Job < ApplicationRecord
  # House Golongan names, from the house Golongan template workbook (generator
  # build_skala_golongan.py, rows 130-137). Screen labels; the number is what the rules read.
  GOLONGAN_NAMES = {
    1 => "Entry-level Operative", 2 => "Skilled Operative", 3 => "Senior Operative / Team Leader",
    4 => "Supervisor / Specialist", 5 => "Section Head / Senior Specialist", 6 => "Manager",
    7 => "Senior Manager / Division Head", 8 => "Executive"
  }.freeze
  # D49 (2), GlassBox Team 2026-10-10 08:04 WIB.
  EMPLOYMENT_TYPES = {
    "tetap_pkwtt" => "Permanent (PKWTT)", "kontrak_pkwt" => "Fixed-term (PKWT)",
    "harian_lepas" => "Daily casual", "magang" => "Internship"
  }.freeze
  WORK_ARRANGEMENTS = { "onsite" => "On-site", "hybrid" => "Hybrid", "remote" => "Remote" }.freeze
  RELOCATIONS = {
    "wajib" => "Must be willing to relocate", "diutamakan" => "Willing to relocate preferred",
    "tidak_perlu" => "Not required"
  }.freeze
  BRIEF_STATUSES = %w[draft complete].freeze

  has_many :stages, dependent: :restrict_with_exception

  # The jobs a staff user may see and act on: a client user (HR PIC, owner, a client admin) only
  # their own company's; DataKita staff (consultant, reviewer, admin without a company) all. Any
  # other user sees none (fail closed). Every staff lookup goes through this (BaseController#org_jobs).
  scope :visible_to, lambda { |user|
    if user&.client_company_id then where(client_company_id: user.client_company_id)
    elsif user&.role.in?(%w[consultant reviewer admin]) then all
    else none
    end
  }
  has_many :job_applications, dependent: :restrict_with_exception
  has_many :knockout_questions, dependent: :restrict_with_exception
  has_many :application_window_events, dependent: :restrict_with_exception
  has_many :activities, -> { order(:position) }, dependent: :restrict_with_exception, inverse_of: :job
  has_many :requirements, -> { order(:position) }, dependent: :restrict_with_exception, inverse_of: :job
  has_many :competencies, -> { order(:position) }, dependent: :restrict_with_exception, inverse_of: :job
  has_many :brief_changes, class_name: "JobBriefChange", dependent: :restrict_with_exception
  has_many :brief_suggestions, -> { order(:id) }, dependent: :restrict_with_exception
  # Feature 07 (D60): the technical test, one row per version.
  has_many :test_cases, -> { order(:version) }, class_name: "TechnicalTestCase", dependent: :restrict_with_exception, inverse_of: :job
  # Optional in the model because the Plan 1 scoring tests build jobs without a company; the
  # portal refuses to open for a job without one (Portal::WindowChange). Plan 2 makes it required
  # when tenant scoping arrives.
  belongs_to :client_company, optional: true
  # Feature 06: the consultant who runs this job (blueprint §1.2). The S1 reviewer may never be
  # this user (Screening::Review and the screening_reviews trigger). Optional: older jobs have none.
  belongs_to :consultant, class_name: "User", optional: true
  has_many :calibration_judgements, dependent: :restrict_with_exception

  # Only per-field invariants live here. The brief rules that span rows (shares 100, weights 100,
  # coverage by Golongan, package recommendation) are Briefs::BriefCheck's, run when a brief is
  # completed: a model validation would refuse every half-filled draft and every scoring-test job.
  validates :title, presence: true
  validates :golongan, inclusion: { in: 1..8 }
  validates :salary_min, :salary_max, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :headcount, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :employment_type, inclusion: { in: EMPLOYMENT_TYPES.keys }, allow_nil: true
  validates :work_arrangement, inclusion: { in: WORK_ARRANGEMENTS.keys }, allow_nil: true
  validates :relocation, inclusion: { in: RELOCATIONS.keys }, allow_nil: true
  validates :package, inclusion: { in: 1..5 }, allow_nil: true
  validates :brief_status, inclusion: { in: BRIEF_STATUSES }

  # The code in the public Lamar address. Random, so the address does not reveal how many jobs
  # exist or let anyone walk the ids.
  before_create { self.public_code ||= SecureRandom.alphanumeric(10).downcase }

  def brief_complete? = brief_status == "complete"
  # Approved before the ad had a text (AI Builder Cup step 02 added it).
  def legacy_ad? = ad_approved_at.present? && ad_text.blank?
  # Who may write the ad: HR PIC always (after approval each save re-approves it, with the tick);
  # the consultant until HR has approved it.
  def ad_writable_by?(user) = user&.role == "hr_pic" || (ad_approved_at.nil? && user&.role == "consultant")

  # Blueprint §2.2 rule 3: once any stage has opened, the fields that drive scoring are frozen
  # (stages, weights, thresholds, knockout questions, requirements, competencies, Golongan,
  # package). Briefs::SaveStep refuses them; the step screens show them read-only.
  def brief_locked? = stages.where.not(opened_at: nil).exists?

  def golongan_label = "G#{golongan} #{GOLONGAN_NAMES[golongan]}"
end
