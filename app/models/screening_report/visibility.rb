module ScreeningReport
  # Who sees names and contact data on the report (rule 14, P14; D62 h7; SPEC §1, §2.1).
  # Names follow the ONE shared rule, CandidateIdentity (D62 h7; feature 07 engine F-01): DataKita
  # staff always; HR PIC and owner once the job's screening stages are closed (the gate S1+S2, or
  # S1 on package 2). This class only adds the report's stricter CONTACT rule.
  #
  #   names     CandidateIdentity.visible_to? (same answer as every other staff screen)
  #   contacts  the consultant always; the HR PIC once confirmed; never the owner or the reviewer
  #             (SPEC §2.1 "email/phone/city (HR and consultant only)"). Stricter than the shared
  #             rule on purpose: the shared rule lets the owner and the reviewer see contacts.
  class Visibility
    def initialize(job, user)
      @job = job
      @user = user
    end

    def confirmed? = @confirmed.nil? ? (@confirmed = CandidateIdentity.screening_confirmed?(@job)) : @confirmed
    def names? = @names.nil? ? (@names = CandidateIdentity.visible_to?(@user, JobApplication.new(job: @job))) : @names
    def contacts? = @user.role == "consultant" || (@user.role == "hr_pic" && confirmed?)
    def blind? = !names?
    # One row: the job-wide answer, or this candidate decided at the gate (CandidateIdentity).
    def name_for?(application) = names? || CandidateIdentity.visible_to?(@user, application)
  end
end
