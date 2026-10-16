# AI Builder Cup step 09: an AI draft (status "draft") or a letter sent to the candidate ("sent",
# the exact text, with its MailDelivery). Append-only.
class CandidateLetter < ApplicationRecord
  include AppendOnly

  KINDS = { "rejection" => "Rejection letter", "offer" => "Offer letter" }.freeze

  belongs_to :job_application
  belongs_to :mail_delivery, optional: true
  belongs_to :actor, class_name: "User"

  def self.latest(application, kind, status) = where(job_application: application, kind:, status:).order(:id).last
end
