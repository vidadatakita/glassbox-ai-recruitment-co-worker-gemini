# Demo data for feature 10, Google integrations (D52; GlassBox Team 18:0x "buat seeder untuk data contohnya
# semua"). EVERYTHING HERE IS INVENTED and marked "(data contoh)". No credential is seeded and no
# Google call is made: the integrations stay OFF in development until someone sets keys.
#
# What it shows, so every state of the D52 screens has data to render:
# - two appointments (on the feature-08 demo job): one whose calendar invite was sent (event id
#   "demo-kalender-001") and one where it failed ("Undangan kalender gagal dikirim" + retry button);
# - one mail delivery that failed (Gmail refused the app password) and one that was sent, so the
#   work queue and the "Email lewat Gmail" row have a failure and a success to show;
# - health rows (google_integration_events) for each integration: login and mail OK, storage failed
#   on the region check, calendar failed on a sync. Pengaturan Sistem shows them once credentials
#   are set (with no credentials every row honestly says "Belum diatur");
# - sign-in log rows: a password sign-in and a refused Google attempt (domain only).
#
# Idempotent: every row is found by its "(data contoh)" marker or by its key before it is created.
# Runs after DemoScreeningReport, whose closed-gate job holds the two candidates used here.
module DemoGoogle
  MARK = "(data contoh)".freeze
  JOB_TITLE = "Supervisor Keuangan (Demo Laporan, gerbang ditutup)".freeze

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
    synced = Appointment.joins(:participation).find_by(participations: { stage_id: s3.id, job_application_id: apps.map(&:id) })
    synced ||= begin
      p3 = Participation.find_or_create_by!(job_application: apps.first, stage: s3) { |p| p.attendance = "pending" }
      Appointment.create!(participation: p3, starts_at: (now + 3.days).change(hour: 9), ends_at: (now + 3.days).change(hour: 10),
                          mode: "onsite", place_or_link: "Kantor contoh, Ruang Rapat 2", contact: "HR #{MARK}")
    end
    synced.update_columns(calendar_event_id: "demo-kalender-001", calendar_status: "synced", calendar_error: nil, calendar_synced_at: now - 2.hours)

    failed = Appointment.find_by("calendar_error LIKE ?", "%#{MARK}%")
    other = failed&.participation&.job_application
    other ||= apps.find { |a| a.id != synced.participation.job_application_id && !a.participations.exists?(stage: s3) && !a.consent_withdrawn_at } ||
            apps.find { |a| a.id != synced.participation.job_application_id && a.participations.exists?(stage: s3) }
    p3b = Participation.find_or_create_by!(job_application: other, stage: s3) { |p| p.attendance = "pending" }
    failed ||= p3b.appointment || Appointment.create!(participation: p3b, starts_at: (now + 4.days).change(hour: 13), ends_at: (now + 4.days).change(hour: 14),
                                                    mode: "video", place_or_link: "https://meet.example/data-contoh", contact: "Konsultan #{MARK}")
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
      GoogleIntegration::Event.create!(integration: "login", source: "check", outcome: "ok", message: "client ID dan secret diterima Google #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "mail", source: "check", outcome: "ok", message: "login SMTP Gmail berhasil #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "storage", source: "check", outcome: "failed", error_class: "GoogleIntegration::Check::Failed",
                                       message: "bucket berada di asia-southeast1, bukan asia-southeast2 (UU PDP: pindahkan sebelum dipakai) #{MARK}", created_at: now - 3.hours)
      GoogleIntegration::Event.create!(integration: "calendar", source: "sync", outcome: "failed", error_class: "Google::Apis::ServerError",
                                       message: "Google::Apis::ServerError: backendError #{MARK}", created_at: now - 1.hour)
    end
    "health rows: #{GoogleIntegration::Event.where('message LIKE ?', "%#{MARK}%").count}"
  end

  def sign_ins(admin, now)
    if SignInEvent.where(user_agent: "Peramban contoh #{MARK}").none?
      SignInEvent.create!(user: admin, auth_method: "password", outcome: "success", ip_address: "127.0.0.1",
                          user_agent: "Peramban contoh #{MARK}", created_at: now - 4.hours)
      SignInEvent.create!(auth_method: "google", outcome: "refused", reason: "unknown_email", email_domain: "gmail.com",
                          ip_address: "127.0.0.1", user_agent: "Peramban contoh #{MARK}", created_at: now - 4.hours)
    end
    "sign-in rows: #{SignInEvent.where(user_agent: "Peramban contoh #{MARK}").count}"
  end
end
