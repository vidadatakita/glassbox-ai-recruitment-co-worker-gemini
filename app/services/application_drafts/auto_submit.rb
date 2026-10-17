module ApplicationDrafts
  # Sends the applications whose test time ran out while the applicant was away (Vida 18 Oct 2026, 05:41:
  # "an applicant who closes the tab before the deadline is submitted automatically"). Before this, such a
  # draft kept its answers but was deleted unsent when the portal closed (ApplicationDrafts::Purge).
  # Run every 5 minutes by ApplicationDraftAutoSubmitJob.
  #
  # Selected: not submitted, test started, CV attached, past the answer deadline (deadline + grace, the
  # same moment the database stops accepting answers). Never touched: a draft whose test never started
  # (the applicant has not taken the test, so nothing is sent on their behalf).
  #
  # Each draft goes through ApplicationDrafts::Submit, the same path as the Send button, so every rule
  # (window, quota, fields, MC scoring, S2 attended) applies; then ApplicationDrafts::AfterSubmit. A
  # draft the applicant sent in the meantime comes back "already submitted" from Submit's row lock and
  # is skipped, so a live Send racing the sweep still makes one application and one e-mail.
  #
  # A closed portal does not stop it (Vida 18 Oct 2026, 05:43: a test that started while the portal was
  # open is still sent): Submit runs with after_close: true, which skips the portal's closed state (HR,
  # date, quota) but still refuses when the first stage (CV screening) is closed (D40). Such a draft is
  # counted as skipped; ApplicationDrafts::Purge keeps a started draft until AUTO_SEND_WINDOW after its
  # deadline, so this sweep always reaches it first. Any other refusal (a field rule) is counted as
  # failed. Both are logged at warn level with the draft id only (no personal data).
  module AutoSubmit
    Result = Data.define(:submitted, :skipped, :failed)
    ALREADY_SENT = "This application is already submitted.".freeze

    module_function

    # Returns the counts; the job logs them.
    def call(now: Time.current)
      counts = { submitted: 0, skipped: 0, failed: 0 }
      due(now).each { |draft| counts[submit_one(draft, now:)] += 1 }
      Result.new(**counts)
    end

    # Coarse filter in SQL (deadline passed); the grace and the window are checked per draft.
    def due(now)
      ApplicationDraft.where(submitted_at: nil).where.not(test_started_at: nil).where(test_due_at: ...now)
                      .includes(:job).order(:id).select { |d| d.time_over?(now) }
    end

    # :submitted, :skipped (nothing to do) or :failed (refused; logged).
    def submit_one(draft, now: Time.current)
      return :skipped unless draft.cv.attached?

      result = Submit.call(draft:, now:, after_close: true)
      if result.errors.any?
        return :skipped if result.errors == [ALREADY_SENT]

        Rails.logger.warn("[auto_submit] draft #{draft.id} not submitted: #{result.errors.join(' ')}")
        return :failed
      end
      # A knockout "No" ends without the acknowledgement, as on the Send button (lamar/not_eligible).
      AfterSubmit.call(draft:, application: result.application, token: result.token) unless result.knocked_out
      :submitted
    rescue Portal::SubmitApplication::Closed
      # Only the first stage closed can refuse an after_close send; the draft stays for the purge.
      Rails.logger.warn("[auto_submit] draft #{draft.id} not submitted: the first stage (CV screening) is closed")
      :skipped
    end
  end
end
