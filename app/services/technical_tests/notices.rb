module TechnicalTests
  # The four technical-test emails of plan §e, each sent AT MOST ONCE per application:
  #   application_received  on submit: the status link and the start deadline (new: before D60 the
  #                         Lamar page showed the link but sent no email)
  #   test_reminder         24 h after submit, only if the test was not started and start_by is ahead
  #   test_receipt          when the answer is stored, with the time it arrived
  #   gate_outcome          once, when the gate "Seleksi CV dan Tes Teknis" has closed
  #
  # Delivery follows the existing house pattern, MailDelivery.deliver! (synchronous, the outcome is
  # recorded, a failure appears in Antrean Kerja), not ActionMailer's deliver_later: a queued mail
  # that fails would be visible only in the job log. Email only; no WhatsApp channel is wired.
  #
  # "Once" is held three ways: the application row is locked while checking and sending, a row of
  # that kind (sent OR failed) stops another send, and a partial unique index
  # (mail_deliveries_one_test_notice) refuses a second row. A failed send therefore stays a failed
  # row for staff to handle; the tick does not retry it into a flood.
  module Notices
    module_function

    def application_received(application, token)
      status = Status.new(application)
      return unless status.can_start?

      once(application, "application_received") do
        CandidateMailer.application_received(application, token, start_by: status.start_by, minutes: status.time_limit)
      end
    end

    def receipt(application)
      attempt = Status.new(application).attempt
      return unless attempt&.answered_at

      once(application, "test_receipt") { CandidateMailer.test_receipt(application, attempt.answered_at) }
    end

    # Due: submitted at least REMINDER_AFTER ago, still not started, start_by still ahead.
    def reminder(application, now: Time.current)
      status = Status.new(application, now:)
      return unless status.state == :not_started && status.attempt.nil?
      return unless now >= TechnicalTests.submitted_at(application) + TechnicalTests::REMINDER_AFTER

      once(application, "test_reminder") { CandidateMailer.test_reminder(application, start_by: status.start_by) }
    end

    # Sent to applicants who went through the gate; not to a knockout at submit (they were told on
    # the Lamar page at once) and never after a withdrawal.
    def gate_outcome(application)
      return if application.knocked_out?

      outcome = GateOutcome.for(application)
      return unless outcome&.closed? && outcome.result != :open

      once(application, "gate_outcome") do
        CandidateMailer.gate_outcome(application, passed: outcome.passed?, reason: outcome.reason)
      end
    end

    def gate_outcomes(job)
      job.job_applications.find_each { |application| gate_outcome(application) }
    end

    def once(application, kind, &build)
      return if application.candidate.nil? || application.consent_withdrawn_at.present?

      application.with_lock do
        next if MailDelivery.exists?(job_application_id: application.id, kind:)

        MailDelivery.deliver!(application, kind, &build)
      end
    end
  end
end
