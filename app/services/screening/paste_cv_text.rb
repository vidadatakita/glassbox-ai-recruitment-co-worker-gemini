module Screening
  # §4.3 "Unreadable CV (scanned image)": the consultant pastes the CV text (typed from the PDF,
  # or from a new CV the candidate sent) and the application goes back to the screening queue.
  # Who pasted it and when is stored on the application (cv_text_by_id, cv_text_at).
  class PasteCvText
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(participation:, user:, text:, now: Time.current)
      @participation = participation
      @user = user
      @text = text.to_s
      @now = now
    end

    def call
      refuse!("Only a consultant can paste CV text.") unless @user.role == "consultant"
      # Also for "Perlu cek manual" (ADR 0004): the consultant pastes a text without the personal data
      # the check found.
      pasteable = @participation.screening_state == "cv_unreadable" ||
                  (@participation.screening_state == "screening_failed" && %w[personal_data too_little_text no_evidence_section].include?(@participation.screening_failure))
      refuse!("CV text is pasted only for a CV that is unreadable or needs a manual check.") unless pasteable
      unless CvText.readable?(@text)
        refuse!("The CV text is too short. Paste the full CV content (at least #{CvText::MIN_LETTERS} letters).")
      end

      ActiveRecord::Base.transaction do
        @participation.job_application.update!(cv_text: @text.strip, cv_text_source: "pasted", cv_text_at: @now,
                                               cv_text_by_id: @user.id)
        @participation.update!(screening_state: nil, screening_state_at: @now)
      end
      Enqueue.call(@participation)
    end

    private

    def refuse!(message) = raise(Refused, message)
  end
end
