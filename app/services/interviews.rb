# The AI interview before CV screening.
module Interviews
  module_function

  # Whether a NEW application on this job gets an interview: the switch is on, the AI is configured, and
  # the reviewer-release mode is off (a live chat cannot wait for a person to release each answer).
  def enabled_for?(job)
    SystemSetting.ai_interview?(company: job.client_company) && Screening::Config.enabled? && !Screening::Config.review_before_ai? &&
      consent_names_it?(job.client_company)
  end

  # The consent text in force for this company names the AI interview (ConsentTemplate#names_ai_interview?).
  # Checked here as well as when the switch is saved: a switch turned on before this rule existed, or a
  # newer consent version that drops the wording, must not create interviews (UU PDP Pasal 21).
  def consent_names_it?(company) = ConsentTemplate.in_force(company:)&.names_ai_interview? || false

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
