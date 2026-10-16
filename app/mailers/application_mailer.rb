class ApplicationMailer < ActionMailer::Base
  # D52 (2): sender and reply-to are installation settings (ENV MAIL_FROM / MAIL_REPLY_TO, or Rails
  # credentials mail.from / mail.reply_to). With Gmail SMTP the sender MUST be the sending mailbox
  # or one of its "Send mail as" aliases, otherwise Gmail rewrites it. Read per message (lambdas),
  # so a test or a restart picks up a change. "from@example.com" stays the fallback, as before.
  def self.setting(credential_key, env_key)
    Rails.application.credentials.dig(:mail, credential_key).to_s.strip.presence || ENV[env_key].to_s.strip.presence
  end

  default from: -> { ApplicationMailer.setting(:from, "MAIL_FROM") || "from@example.com" },
          reply_to: -> { ApplicationMailer.setting(:reply_to, "MAIL_REPLY_TO") }
  layout "mailer"
end
