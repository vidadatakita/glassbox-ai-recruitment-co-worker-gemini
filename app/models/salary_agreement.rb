# AI Builder Cup step 08: the owner's agreed salary for one application (the database allows only
# the owner, and a note when it is outside the band). A correction is a new row; the newest counts.
class SalaryAgreement < ApplicationRecord
  include AppendOnly

  belongs_to :job_application
  belongs_to :salary_recommendation, optional: true
  belongs_to :decided_by, class_name: "User"

  def self.latest_for(application) = where(job_application: application).order(:id).last
end
