# Staff account (Rails 8 authentication generator) with a role from blueprint §1.2. Hiring
# managers and candidates are not users; they use one-time links.
class User < ApplicationRecord
  ROLE_LABELS = {
    "owner" => "Owner", "hr_pic" => "HR owner", "consultant" => "Consultant",
    "reviewer" => "Reviewer", "admin" => "Admin"
  }.freeze

  has_secure_password
  has_many :sessions, dependent: :destroy
  belongs_to :client_company, optional: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true
  validates :role, inclusion: { in: ROLE_LABELS.keys }
end
