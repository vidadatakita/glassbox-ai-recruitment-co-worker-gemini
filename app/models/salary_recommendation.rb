# AI Builder Cup step 08: the AI's position within the job's salary band (0 = bottom, 1 = top) with
# its reasons; `amount` is the code's rupiah for that position (Progression::RecommendSalary).
# Advisory only; the owner's SalaryAgreement is the decision.
class SalaryRecommendation < ApplicationRecord
  include AppendOnly

  belongs_to :job_application
  belongs_to :requested_by, class_name: "User"

  def self.latest_for(application) = where(job_application: application).order(:id).last
  def ready? = status == "ready"
end
