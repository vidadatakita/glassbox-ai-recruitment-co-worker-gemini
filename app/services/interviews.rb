# The AI interview before CV screening (docs/superpowers/specs/2026-10-16-ai-interview-design.md).
module Interviews
  module_function

  # Whether a NEW application on this job gets an interview: the switch is on, the AI is configured, and
  # the reviewer-release mode is off (a live chat cannot wait for a person to release each answer).
  def enabled_for?(job)
    SystemSetting.ai_interview?(company: job.client_company) && Screening::Config.enabled? && !Screening::Config.review_before_ai?
  end

  # Who may read the candidate's answers: the same rule as the technical-test answer file.
  def viewable_by?(user, job) = TechnicalTests.answer_downloadable_by?(user, job)

  # A chat the candidate is in right now: started and still inside its 30 minutes. Staff actions never cut it off.
  def live?(interview, now: Time.current) = interview.started_at.present? && now < interview.due_at

  # The application's interview while it is still open, else nil.
  def open_for(application)
    interview = application.interview
    interview if interview&.open?
  end
end
