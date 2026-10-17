# Staff account (Rails 8 authentication generator) with a role from blueprint §1.2. Hiring
# managers and candidates are not users; they use one-time links.
class User < ApplicationRecord
  # Three roles (GlassBox Team, 17 Oct 2026). hr_admin prepares and decides (brief, ad, portal,
  # screening start, calibration, test case, the step-9 decision); hr_manager checks (Send to Gemini,
  # review of flagged results, technical-test scoring, salary). superadmin passes every role check
  # (Staff::BaseController#require_role!, the database guards); the per-person rule that the reviewer
  # is never the vacancy's consultant still binds everyone, superadmin included.
  ROLE_LABELS = {
    "superadmin" => "Superadmin", "hr_admin" => "HR Admin", "hr_manager" => "HR Manager"
  }.freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  belongs_to :client_company, optional: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true
  validates :role, inclusion: { in: ROLE_LABELS.keys }
end
