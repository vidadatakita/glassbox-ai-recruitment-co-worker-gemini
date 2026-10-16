# "Minta link baru" from someone who lost their status link and cannot be matched
# automatically. A consultant handles it from the work queue.
class LinkRequest < ApplicationRecord
  belongs_to :job_application, optional: true
  # The job of the code typed, when the code exists: the request reaches only that company.
  belongs_to :job, optional: true

  validates :contact, presence: true
end
