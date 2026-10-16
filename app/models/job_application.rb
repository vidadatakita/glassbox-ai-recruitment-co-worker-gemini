# The blueprint's "Application" record (named JobApplication to avoid confusion with
# Rails.application). Portal applications carry a candidate, consent and a CV; the Plan 1
# scoring tests build bare applications, so candidate is optional here and the database check
# job_applications_consent_recorded makes consent mandatory whenever a candidate is present.
class JobApplication < ApplicationRecord
  STATUS_LABELS = {
    "active" => "In progress", "eliminated" => "Not passed", "hired" => "Hired",
    "withdrawn" => "Withdrawn", "awaiting_consent" => "Awaiting consent",
    "no_consent" => "No consent"
  }.freeze

  belongs_to :job
  belongs_to :candidate, optional: true
  belongs_to :consent_template, optional: true
  has_many :participations, dependent: :restrict_with_exception
  has_many :offer_documents, dependent: :restrict_with_exception
  has_many :mail_deliveries, dependent: :restrict_with_exception
  has_one_attached :cv

  # Rule 16: a "tidak" to any knockout question.
  def knocked_out? = knockout_answers.to_h.value?("tidak")
end
