# An offer letter uploaded by the consultant (E24, D33): the PDF, the start date and what to
# prepare for day one. The candidate accepts or declines once per version; a newer version
# replaces the older one, whose buttons stop working. Accepted at most once per application
# (unique partial index offer_documents_one_acceptance).
class OfferDocument < ApplicationRecord
  RESPONSES = %w[accepted declined].freeze

  belongs_to :job_application
  delegate :job, to: :job_application # the record's company is its job's (BaseController#org_find)
  has_one_attached :pdf

  validates :version, :start_at, :valid_until, :day_one_notes, :uploaded_by_id, presence: true
  validates :response, inclusion: { in: RESPONSES }, allow_nil: true

  def self.latest_for(application)
    where(job_application: application).order(version: :desc).first
  end

  def latest? = self.class.latest_for(job_application)&.id == id
  def accepted? = response == "accepted"
end
