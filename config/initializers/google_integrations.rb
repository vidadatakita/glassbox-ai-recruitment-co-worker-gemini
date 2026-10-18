# D52 Google integrations: the parts that must be set at boot. Login lives in omniauth.rb.
#
# Signed URLs for stored files expire after 5 minutes (Rails default: 5 minutes too; set here so
# the number is written down). GlassBox never shows a storage URL to anyone: every download is
# proxied through a controller with a role check (send_data), so this is defence in depth for the
# Active Storage blob routes only.
Rails.application.config.active_storage.service_urls_expire_in = 5.minutes

Rails.application.config.after_initialize do
  # (3) Half-configured storage must not start: "google" chosen without a bucket and a service
  # account would accept a CV upload and then fail on it. Same rule as a missing TENANCY (ONP-2).
  GoogleIntegration::Config.validate_storage!

  # (2) Email through Gmail / Google Workspace SMTP, PRODUCTION ONLY. Development keeps writing
  # mail to tmp/mails (:file) and tests keep :test, whatever credentials a developer has.
  # smtp.gmail.com:587 with STARTTLS required and a Workspace APP PASSWORD (a team
  # decision). A refused login or a dropped connection raises a
  # Net::SMTP*/socket error, which MailDelivery.deliver! records as "failed" and the work queue
  # shows (ONP-12); nothing here swallows it. Timeouts are short so a stuck Gmail cannot hold a
  # candidate's request for long: the send is synchronous on purpose (MailDelivery).
  GoogleIntegration::Config.apply_mail!(ActionMailer::Base, production: Rails.env.production?)
end
