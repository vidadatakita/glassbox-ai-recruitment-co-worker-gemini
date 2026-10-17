module ApplicationDrafts
  # What follows a successful Submit, whoever pressed it: the applicant (ApplyController#submit) or the
  # clock (ApplicationDrafts::AutoSubmit, when the test time ran out with the tab closed). One copy, so
  # the two paths cannot drift: the acknowledgement e-mail carries the status link, the only way an
  # applicant who closed the tab learns where to follow the application; the written answers get their
  # AI suggestion in the background (slice C).
  module AfterSubmit
    module_function

    def call(draft:, application:, token:)
      MailDelivery.deliver!(application, "application_ack") { CandidateMailer.application_ack(application, token) }
      # updated_at marks when "pending" began: ApplicationDraft#ai_retryable? times a lost run from it.
      draft.update_columns(ai_status: "pending", updated_at: Time.current)
      BankAnswerAiRateJob.perform_later(draft.id)
    end
  end
end
