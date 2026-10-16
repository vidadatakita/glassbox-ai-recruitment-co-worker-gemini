# net/smtp defines Net::SMTPError. Without this require the constant exists only once the SMTP
# delivery method has loaded it, so under :test, :file or :sendmail the rescue clause below raised
# NameError instead of recording the failure (test engine F2, 2026-10-10).
require "net/smtp"
require "socket"

# Sends one email to a candidate and records the outcome (ONP-12, house rule "the operator must
# see failure in the interface"). Sent synchronously so the screen that triggered it can say
# at once whether it worked; a failure is stored and listed in the work queue.
class MailDelivery < ApplicationRecord
  # Labels shown in Antrean Kerja for a failed send. The four technical-test kinds (D60, plan §e)
  # are sent at most once per application (TechnicalTests::Notices; index
  # mail_deliveries_one_test_notice).
  LABELS = {
    "status_link" => "Status link", "offer_code" => "Offer code",
    "application_received" => "Application and technical test confirmation", "test_reminder" => "Technical test reminder",
    "test_receipt" => "Test answer receipt", "gate_outcome" => "CV screening and technical test result",
    # AI Builder Cup step 09: letters the HR PIC sends (CandidateLetter).
    "rejection_letter" => "Rejection letter", "offer_letter" => "Offer letter",
    # AI Builder Cup step 04: the acknowledgement of an application on a job without a technical test.
    "application_ack" => "Application confirmation"
  }.freeze
  KINDS = LABELS.keys.freeze

  belongs_to :job_application
  delegate :job, to: :job_application # the record's company is its job's (BaseController#org_find)

  scope :failed_open, -> { where(status: "failed", handled_at: nil) }

  # Who marked a failure handled (test engine F12); only consultants may (F11).
  def mark_handled!(user)
    update!(handled_at: Time.current, handled_by_id: user.id)
  end

  # Yields to build the message (an ActionMailer::MessageDelivery) and delivers it now.
  # Returns the MailDelivery row; check #sent?.
  def self.deliver!(application, kind)
    raise ArgumentError, "unknown mail kind #{kind}" unless KINDS.include?(kind)

    yield.deliver_now
    create!(job_application: application, kind:, status: "sent")
  rescue Net::SMTPError, SocketError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
    # Delivery failures only: SMTP refusals, a mail host that does not resolve (SocketError, the
    # usual setup mistake; test engine F1), connection and TLS errors, timeouts. Programming
    # errors (NoMethodError, a broken template) are NOT caught, so they fail loudly in tests.
    create!(job_application: application, kind:, status: "failed",
            error_class: e.class.name, error_message: failure_summary(e))
  end

  # What is STORED about a failure (engine 07 run 2, F-09): the error class (its own column), a
  # category, and the SMTP status code when the server gave one. NEVER the raw message: an SMTP
  # refusal names the recipient ("550 5.1.1 <a@b>: Recipient address rejected"), and Antrean Kerja
  # shows this text to HR PIC while candidates are still numbers (D62 h7). Conventions §9.4: the
  # candidate's email lives on the candidate record only. Staff who may see the address open the
  # candidate (CandidateIdentity rule); the failure row never repeats it.
  CATEGORIES = {
    "refused_recipient" => "Recipient address refused by the mail server", "auth" => "Login to the mail server refused",
    "timeout" => "The mail server did not answer in time", "connection" => "Could not connect to the mail server",
    "other" => "The mail server refused the delivery"
  }.freeze
  SMTP_CODE = /\b([45]\d\d)(?:[ -]([245]\.\d{1,3}\.\d{1,3}))?\b/

  def self.failure_summary(error)
    code = error.message.to_s[SMTP_CODE] && [Regexp.last_match(1), Regexp.last_match(2)].compact.join(" ")
    text = CATEGORIES.fetch(failure_category(error, code))
    code ? "#{text} (SMTP #{code})" : text
  end

  def self.failure_category(error, code)
    return "auth" if defined?(Net::SMTPAuthenticationError) && error.is_a?(Net::SMTPAuthenticationError)
    return "timeout" if error.is_a?(Timeout::Error)
    return "refused_recipient" if code.to_s.match?(/\A55[0-3]\b/)
    return "connection" if error.is_a?(SocketError) || error.is_a?(SystemCallError) || error.is_a?(IOError) || error.is_a?(OpenSSL::SSL::SSLError)

    "other"
  end

  # Masks any email address in a stored text: rows written before F-09 carry raw SMTP messages.
  EMAIL_IN_TEXT = /[^\s<>"'()\[\],;:]+@[^\s<>"'()\[\],;:]+/
  def error_text = error_message.to_s.gsub(EMAIL_IN_TEXT, "[address redacted]")

  def sent? = status == "sent"
end
