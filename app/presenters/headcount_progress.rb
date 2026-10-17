# How many people the vacancy needs and how many places are filled (Vida, 17 Oct 2026, 22:46-22:47:
# "filled = the applicants who reached Salary agreed"). One owner of the count, used by the applicant
# portal card and anywhere else it is shown.
#
# filled: applications of this vacancy with an agreed salary (SalaryAgreement), minus those who withdrew
#         their consent and those whose newest offer was DECLINED (a declined offer frees the place
#         again; the team default, since Vida's rule names the salary step only).
# accepted: of the filled, how many accepted the newest offer.  open: needed minus filled, never below 0.
class HeadcountProgress
  attr_reader :job

  def initialize(job)
    @job = job
  end

  def needed = job.headcount.to_i

  def filled_applications
    @filled_applications ||= JobApplication.where(job_id: job.id, consent_withdrawn_at: nil)
                                           .where(id: SalaryAgreement.select(:job_application_id))
                                           .to_a.reject { |application| OfferDocument.latest_for(application)&.response == "declined" }
  end

  def filled = filled_applications.size
  def accepted = filled_applications.count { |application| OfferDocument.latest_for(application)&.accepted? }
  def open = [needed - filled, 0].max
  def over? = filled > needed
  def complete? = needed.positive? && filled >= needed
  def percent = needed.positive? ? [filled * 100 / needed, 100].min : 0
end
