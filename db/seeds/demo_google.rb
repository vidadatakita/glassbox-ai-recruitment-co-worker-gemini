# Demo data for feature 10, Google integrations (D52; GlassBox Team 18:0x "build a seeder for all the
# sample data"). EVERYTHING HERE IS INVENTED and marked "(sample data)"; all text is English (owner's
# rule, 17 Oct 2026). No credential is seeded and no Google call is made: the integrations stay OFF
# in development until someone sets keys.
#
# What it shows, so every state of the D52 screens has data to render:
# - two appointments (on the feature-08 demo job): one whose calendar invite was sent (event id
#   "demo-calendar-001") and one where it failed (the failed-invite notice + retry button);
# - one mail delivery that failed (Gmail refused the app password) and one that was sent, so the
#   work queue and the "Email via Gmail" row have a failure and a success to show;
# - health rows (google_integration_events) for each integration: login and mail OK, storage failed
#   on the region check, calendar failed on a sync. System settings shows them once credentials
#   are set (with no credentials every row honestly says "Not set");
# - sign-in log rows: a password sign-in and a refused Google attempt (domain only).
#
# Idempotent: every row is found by its "(sample data)" marker or by its key before it is created.
# The marker was "(data contoh)" before 17 Oct 2026. On a development database seeded before then,
# the two appointments are reused (the failed one is re-marked), but the failed mail row (1), the
# health rows (4) and the sign-in rows (2) are written again in English beside the old ones; reset
# the database to drop the old rows.
# Runs after DemoScreeningReport, whose closed-gate job holds the two candidates used here.
require_relative "demo_screening_report"

module DemoGoogle
  MARK = "(sample data)".freeze
  # Read from DemoScreeningReport, never copied: a copied title that drifts from the real one makes
  # run return "skipped" and the whole Google demo disappears without an error.
  JOB_TITLE = DemoScreeningReport::TITLES.fetch(:closed)

  module_function

  def run(consultant:, admin:, now: Time.current)
    job = Job.find_by(title: JOB_TITLE)
    return [ "skipped: run DemoScreeningReport first (job #{JOB_TITLE} not found)" ] unless job

    out = []
    ActiveRecord::Base.transaction do
      out << appointments(job, consultant, now)
      out << mail(job, now)
      out << health(now)
      out << sign_ins(admin, now)
    end
    out
  end

  def appointments(job, consultant, now)
    s3 = job.stages.find_by!(code: "S3")
    apps = job.job_applications.joins(:candidate).order("candidates.name").to_a
    # Ordered: without it Postgres may return the failed appointment first, flip it to synced, and a
    # second run then writes a duplicate (seen once in about 41 runs, 17 Oct 2026).
    synced = Appointment.joins(:participation).order(:id).find_by(participations: { stage_id: s3.id, job_application_id: apps.map(&:id) })
    synced ||= begin
      p3 = Participation.find_or_create_by!(job_application: apps.first, stage: s3) { |p| p.attendance = "pending" }
      Appointment.create!(participation: p3, starts_at: (now + 3.days).change(hour: 9), ends_at: (now + 3.days).change(hour: 10),
                          mode: "onsite", place_or_link: "Sample office, Meeting Room 2", contact: "HR #{MARK}")
    end
    synced.update_columns(calendar_event_id: "demo-calendar-001", calendar_status: "synced", calendar_error: nil, calendar_synced_at: now - 2.hours)

    failed = Appointment.find_by("calendar_error LIKE ?", "%#{MARK}%")
    other = failed&.participation&.job_application
    other ||= apps.find { |a| a.id != synced.participation.job_application_id && !a.participations.exists?(stage: s3) && !a.consent_withdrawn_at } ||
            apps.find { |a| a.id != synced.participation.job_application_id && a.participations.exists?(stage: s3) }
    p3b = Participation.find_or_create_by!(job_application: other, stage: s3) { |p| p.attendance = "pending" }
    failed ||= p3b.appointment || Appointment.create!(participation: p3b, starts_at: (now + 4.days).change(hour: 13), ends_at: (now + 4.days).change(hour: 14),
                                                    mode: "video", place_or_link: "https://meet.example/sample-data", contact: "Consultant #{MARK}")
    if AppointmentChange.where(appointment: [ synced, failed ]).none?
      [ synced, failed ].each do |a|
        AppointmentChange.create!(appointment: a, old_starts_at: nil, new_starts_at: a.starts_at, actor_id: consultant.id, created_at: now - 3.hours)
      end
    end
    failed.update_columns(calendar_status: "failed", calendar_event_id: nil, calendar_synced_at: now - 1.hour,
                          calendar_error: "Google::Apis::ServerError: backendError #{MARK}")
    "appointments: ##{synced.id} synced (application ##{synced.participation.job_application_id}), ##{failed.id} failed (application ##{other.id})"
  end

  def mail(job, now)
    application = job.job_applications.order(:id).first
    unless MailDelivery.where(error_message: "535-5.7.8 Username and Password not accepted #{MARK}").exists?
      MailDelivery.create!(job_application: application, kind: "status_link", status: "failed", error_class: "Net::SMTPAuthenticationError",
                           error_message: "535-5.7.8 Username and Password not accepted #{MARK}", created_at: now - 50.minutes)
    end
    failed = MailDelivery.where(error_message: "535-5.7.8 Username and Password not accepted #{MARK}").count
    "mail: #{failed} failed demo delivery on application ##{application.id} (sent rows already exist: #{MailDelivery.where(status: 'sent').count})"
  end

  def health(now)
    if GoogleIntegration::Event.where("message LIKE ?", "%#{MARK}%").none?
      GoogleIntegration::Event.create!(integration: "login", source: "check", outcome: "ok", message: "client ID and secret accepted by Google #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "mail", source: "check", outcome: "ok", message: "Gmail SMTP login succeeded #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "storage", source: "check", outcome: "failed", error_class: "GoogleIntegration::Check::Failed",
                                       message: "bucket is in asia-southeast1, not asia-southeast2 (PDP Law: move it before use) #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "calendar", source: "sync", outcome: "failed", error_class: "Google::Apis::ServerError",
                                       message: "Google::Apis::ServerError: backendError #{MARK}", created_at: now - 1.hour)
    end
    "health rows: #{GoogleIntegration::Event.where('message LIKE ?', "%#{MARK}%").count}"
  end

  def sign_ins(admin, now)
    if SignInEvent.where(user_agent: "Sample browser #{MARK}").none?
      SignInEvent.create!(user: admin, auth_method: "password", outcome: "success", ip_address: "127.0.0.1",
                          user_agent: "Sample browser #{MARK}", created_at: now - 4.hours)
      SignInEvent.create!(auth_method: "google", outcome: "refused", reason: "unknown_email", email_domain: "gmail.com",
                          ip_address: "127.0.0.1", user_agent: "Sample browser #{MARK}", created_at: now - 4.hours)
    end
    "sign-in rows: #{SignInEvent.where(user_agent: "Sample browser #{MARK}").count}"
  end
end
