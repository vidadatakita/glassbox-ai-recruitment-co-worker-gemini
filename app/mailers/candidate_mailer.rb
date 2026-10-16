# Emails to candidates (D36). Plain English, short; the subjects are read by the tests that find a
# mail by subject (e.g. the offer code mail by "code"). The sender is the client's
# mail domain on a client-side install (ONP-12; MAIL_* settings arrive with Plan 4).
class CandidateMailer < ApplicationMailer
  def status_link(application, token)
    @application = application
    @job = application.job
    @url = candidate_status_url(token:)
    mail(to: application.candidate.email, subject: "Your application status link: #{@job.title}")
  end

  # AI Builder Cup step 04: every application is acknowledged by email with its status link, also on
  # a job without a technical test (that one gets application_received instead).
  def application_ack(application, token)
    @application = application
    @job = application.job
    @url = candidate_status_url(token:)
    mail(to: application.candidate.email, subject: "Application received: #{@job.title}")
  end

  def offer_code(application, code)
    @application = application
    @code = code
    @minutes = (OfferAccessCode::CODE_LIFETIME / 60).to_i
    mail(to: application.candidate.email, subject: "Your code to open the job offer")
  end

  # D60 plan §e, technical-test notices (TechnicalTests::Notices sends each at most once). Times are
  # shown in WIB; no score, threshold or other candidate is ever in a candidate email.
  def application_received(application, token, start_by:, minutes:)
    @application = application
    @job = application.job
    @url = candidate_status_url(token:)
    @test_url = candidate_status_test_url(token:)
    @start_by = start_by
    @minutes = minutes
    mail(to: application.candidate.email, subject: "Application received and technical test: #{@job.title}")
  end

  # No link in the reminder: the status token is stored only as a digest, so it cannot be put in a
  # later email. The candidate opens the link from the first email, or asks for a new one.
  def test_reminder(application, start_by:)
    @application = application
    @job = application.job
    @start_by = start_by
    @link_request_url = new_link_request_url
    mail(to: application.candidate.email, subject: "Technical test reminder: #{@job.title}")
  end

  def test_receipt(application, answered_at)
    @application = application
    @job = application.job
    @answered_at = answered_at
    mail(to: application.candidate.email, subject: "Technical test answer received: #{@job.title}")
  end

  # AI Builder Cup step 09: a letter the HR PIC wrote (often from an AI draft) and sent as is.
  def letter(application, subject:, body:)
    @body = body
    mail(to: application.candidate.email, subject:)
  end

  def gate_outcome(application, passed:, reason:)
    @application = application
    @job = application.job
    @passed = passed
    @reason = reason
    mail(to: application.candidate.email, subject: "CV screening and technical test result: #{@job.title}")
  end
end
