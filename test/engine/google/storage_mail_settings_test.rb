require "test_helper"
require "active_storage/service/disk_service"

# Test engine, feature 10 (D52 (2)(3) and the settings screen): storage migration, Gmail
# failure recording, Settings access, and house wording on every D52 surface.
#
# Claim -> mutant -> test that goes red:
# - "the local file is NEVER deleted" -> @source.delete after copy -> builder test + G-S1/G-S2
# - "a blob that fails stays on local and keeps working; the run continues" -> G-S2
# - "a refused Gmail login is recorded as failed, never raised, never lost" -> G-M1
# - "Settings is admin-only" -> G-A1 (every other role)
class GoogleEngineStorageMailSettingsTest < ActionDispatch::IntegrationTest
  KEY_MARKER = "ENGINE-KUNCI-PRIVAT-RAHASIA".freeze

  def make_blob(bytes)
    blob = ActiveStorage::Blob.create!(key: "engine#{SecureRandom.hex(6)}", filename: "cv.pdf", content_type: "application/pdf",
                                       byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes), service_name: "local")
    @source.upload(blob.key, StringIO.new(bytes), checksum: blob.checksum)
    blob
  end

  def with_disks
    @root = Dir.mktmpdir("glassbox-engine-migrate")
    @source = ActiveStorage::Service::DiskService.new(root: File.join(@root, "local"))
    @target = ActiveStorage::Service::DiskService.new(root: File.join(@root, "bucket"))
    yield
  ensure
    FileUtils.rm_rf(@root)
  end

  def migrate(target: @target) = GoogleIntegration::StorageMigration.new(dry_run: false, source: @source, target:, target_name: "google").run

  # G-S1. An upload that dies half-way (network) leaves blob AND local bytes exactly as before,
  # and the next blob is still migrated.
  test "a failed upload keeps the blob on local with its bytes; the run continues with the next blob" do
    with_disks do
      first = make_blob("%PDF-1.4 satu\n%%EOF\n")
      second = make_blob("%PDF-1.4 dua\n%%EOF\n")
      flaky = @target.dup
      first_key = first.key
      real_upload = @target.method(:upload)
      flaky.define_singleton_method(:upload) do |key, io, **opts|
        raise Errno::ECONNRESET, "koneksi putus" if key == first_key

        real_upload.call(key, io, **opts)
      end

      lines = migrate(target: flaky).index_by(&:blob_id)
      assert_equal :failed, lines[first.id].outcome
      assert_equal :copied, lines[second.id].outcome, "one failure does not stop the run"
      assert_equal "local", first.reload.service_name
      assert_equal "google", second.reload.service_name
      assert_equal "%PDF-1.4 satu\n%%EOF\n", @source.download(first.key), "local bytes untouched"
      assert_equal "%PDF-1.4 dua\n%%EOF\n", @source.download(second.key), "local copy kept after a successful copy"
    end
  end

  # G-S2. A local file already corrupted (checksum mismatch) is never copied or re-pointed.
  test "a corrupted local file is reported failed, not copied, and the blob is not re-pointed" do
    with_disks do
      blob = make_blob("%PDF-1.4 asli\n%%EOF\n")
      File.binwrite(@source.path_for(blob.key), "%PDF-1.4 RUSAK\n%%EOF\n")
      line = migrate.find { |l| l.blob_id == blob.id }
      assert_equal :failed, line.outcome
      refute @target.exist?(blob.key), "nothing with a wrong checksum reaches the bucket"
      assert_equal "local", blob.reload.service_name
      assert @source.exist?(blob.key)
    end
  end

  # G-S3 (part of FINDING F-10-01). storage.yml parses the service-account JSON with ERB at load
  # time; a malformed key raises with the key text in the message (boot crash output / logs).
  test "config/storage.yml with a malformed service-account key fails without quoting the key" do
    broken = %({"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\n#{KEY_MARKER}\n-----END PRIVATE KEY-----\n"})
    message = with_env("GOOGLE_SERVICE_ACCOUNT_JSON" => broken) do
      ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
      nil
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end
    refute_includes message.to_s, KEY_MARKER
  end

  # G-M1. What Gmail answers to a wrong app password: 535 5.7.8. It must become a failed
  # MailDelivery row (shown in the Work queue), not an exception and not silence.
  test "a refused Gmail login is recorded as a failed MailDelivery" do
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    refused = Object.new
    refused.define_singleton_method(:deliver_now) do
      raise Net::SMTPAuthenticationError.new(Net::SMTP::Response.parse("535-5.7.8 Username and Password not accepted"))
    end
    delivery = nil
    assert_difference -> { MailDelivery.where(status: "failed").count } => 1 do
      delivery = MailDelivery.deliver!(application, "status_link") { refused }
    end
    refute delivery.sent?
    assert_equal "Net::SMTPAuthenticationError", delivery.error_class
    assert_match "535", delivery.error_message

    # The row above is only written if Mail RAISES the refusal. With raise_delivery_errors false,
    # Mail swallows the 535 and MailDelivery records "sent" for an email that never left.
    mailer = Class.new(ActionMailer::Base)
    with_env("GOOGLE_MAIL_USERNAME" => "hr@uji.example", "GOOGLE_MAIL_APP_PASSWORD" => "engine-app-pass") do
      assert GoogleIntegration::Config.apply_mail!(mailer, production: true), "control: switched to Gmail"
    end
    assert_equal true, mailer.raise_delivery_errors, "Gmail SMTP must raise delivery errors"

    tls = Object.new
    tls.define_singleton_method(:deliver_now) { raise OpenSSL::SSL::SSLError, "STARTTLS gagal" }
    assert_equal "failed", MailDelivery.deliver!(application, "status_link") { tls }.status
  end

  # G-A1. Every non-superadmin role, not one sample.
  test "Settings (with Google integrations) is closed to every role except superadmin" do
    (User::ROLE_LABELS.keys - [ "superadmin" ]).each do |role|
      sign_in_as(staff_user(role))
      get staff_settings_path
      assert_redirected_to staff_jobs_path, "#{role} must not see Settings"
      sign_out
    end
    sign_in_as(staff_user("admin"))
    get staff_settings_path
    assert_response :success
    assert_match "Google integrations", response.body, "control: superadmin sees the section"
  end

  # G-A2. Every secret, every state (off / active / failed), never on the page.
  test "no client secret, app password or private key on the page in any state" do
    secrets = { "GOOGLE_OAUTH_CLIENT_ID" => "engine-id.apps.googleusercontent.com", "GOOGLE_OAUTH_CLIENT_SECRET" => "ENGINE-CLIENT-SECRET",
                "GOOGLE_MAIL_USERNAME" => "hr@uji.example", "GOOGLE_MAIL_APP_PASSWORD" => "ENGINE-APP-PASSWORD",
                "GOOGLE_STORAGE_BUCKET" => "engine-bucket", "GOOGLE_CALENDAR_ID" => "jadwal@uji.example",
                "GOOGLE_SERVICE_ACCOUNT_JSON" => fake_service_account_json }
    private_key_line = JSON.parse(fake_service_account_json)["private_key"].lines[1].strip
    sign_in_as(staff_user("admin"))
    pages = []
    with_env(secrets) { get staff_settings_path; pages << response.body }
    GoogleIntegration::Event.record!(:mail, source: :check, error: RuntimeError.new("x"), message: "Net::SMTPAuthenticationError: 535")
    GoogleIntegration::Event.record!(:login, source: :check, error: RuntimeError.new("x"), message: "Google refused the client ID or secret (invalid_client)")
    with_env(secrets) { get staff_settings_path; pages << response.body }
    assert_match "Last failed", pages.last, "control: the failed state rendered"
    pages.each do |page|
      [ "ENGINE-CLIENT-SECRET", "ENGINE-APP-PASSWORD", private_key_line, "BEGIN PRIVATE KEY" ].each { |s| refute_includes page, s }
    end
  end

  # G-W1. House wording and form rules on every D52 surface (source scan; the screens are also
  # rendered by G-A2 and the calendar tests).
  test "D52 screens and messages use the house words and never disable a button" do
    files = %w[app/controllers/google_sessions_controller.rb app/controllers/staff/appointments_controller.rb
               app/models/google_integration/status.rb app/services/google_integration/check.rb
               app/views/sessions/new.html.erb app/views/staff/applications/_calendar_status.html.erb
               app/views/staff/settings/_google_integrations.html.erb lib/tasks/google.rake]
    files.each do |file|
      text = File.read(Rails.root.join(file))
      assert_no_match(/\b(terapkan|diterapkan|tautan|berkas|unggah|diunggah|mengunggah|tatap muka)\b/i, text, file)
      assert_no_match(/disabled:\s*true|data-disable-with|disable_with/, text, file)
    end
  end
end
