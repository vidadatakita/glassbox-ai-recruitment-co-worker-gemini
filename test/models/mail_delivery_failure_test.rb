require "test_helper"
require "net/smtp"

# Engine 07 run 2, F-09: a failed send stores the error class, a category and the SMTP code, never
# the raw server text, which names the recipient.
class MailDeliveryFailureTest < ActiveSupport::TestCase
  test "a 550 refusal is stored as refused recipient + code, with no address" do
    error = Net::SMTPFatalError.new("550 5.1.1 <dewi@uji.example>: Recipient address rejected: User unknown")
    summary = MailDelivery.failure_summary(error)
    assert_equal "Recipient address refused by the mail server (SMTP 550 5.1.1)", summary
    refute_includes summary, "@"
  end

  test "categories: auth with its code, timeout, connection, other" do
    assert_equal "Login to the mail server refused (SMTP 535 5.7.8)", MailDelivery.failure_summary(Net::SMTPAuthenticationError.new("535-5.7.8 Username and Password not accepted"))
    assert_equal "The mail server did not answer in time", MailDelivery.failure_summary(Net::OpenTimeout.new("execution expired"))
    assert_equal "Could not connect to the mail server", MailDelivery.failure_summary(SocketError.new("getaddrinfo: x@y"))
    assert_equal "The mail server refused the delivery (SMTP 452 4.2.2)", MailDelivery.failure_summary(Net::SMTPServerBusy.new("452 4.2.2 mailbox full <a@b.c>"))
  end

  test "deliver! stores the summary, not the message; older rows are masked on display" do
    application = JobApplication.create!(job: Job.create!(title: "Uji", golongan: 2, client_company: default_company))
    error = Net::SMTPFatalError.new("550 5.1.1 <rina@uji.example>: rejected")
    delivery = MailDelivery.deliver!(application, "test_receipt") { raise error }
    assert_equal "Net::SMTPFatalError", delivery.error_class
    refute_includes delivery.error_message, "rina@uji.example"
    old = MailDelivery.create!(job_application: application, kind: "status_link", status: "failed", error_class: "X",
                               error_message: "550 <rina@uji.example> rejected")
    assert_equal "550 <[address redacted]> rejected", old.error_text
  end
end
