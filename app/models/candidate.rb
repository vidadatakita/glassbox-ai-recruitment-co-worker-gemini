# A person who applied. Personal data under UU 27/2022: shown only to staff and to the
# candidate's own status page, never to another candidate.
class Candidate < ApplicationRecord
  has_many :job_applications, dependent: :restrict_with_exception

  validates :name, :email, :phone, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
end
