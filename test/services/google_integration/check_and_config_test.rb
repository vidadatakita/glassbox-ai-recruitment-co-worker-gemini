require "test_helper"

# D52: `glassbox:google:check` (one harmless call each), the settings that switch each integration
# on, the boot refusal for half-configured storage, the Gmail SMTP switch and the mail sender.
class GoogleIntegration::CheckAndConfigTest < ActiveSupport::TestCase
  LOGIN_ENV = { "GOOGLE_OAUTH_CLIENT_ID" => "uji-id", "GOOGLE_OAUTH_CLIENT_SECRET" => "uji-secret" }.freeze
  BUCKET_URL = "https://storage.googleapis.com/storage/v1/b/glassbox-uji-bucket".freeze

  def storage_env(region: "asia-southeast2")
    { "GOOGLE_SERVICE_ACCOUNT_JSON" => fake_service_account_json, "GOOGLE_STORAGE_BUCKET" => "glassbox-uji-bucket",
      "GOOGLE_STORAGE_REGION" => region }
  end

  def stub_any_token!
    stub_google_token!
    stub_request(:post, GoogleStubs::TOKEN_URL).with { |req| req.body.include?("jwt-bearer") }
                                               .to_return(json_response({ access_token: "uji-token", token_type: "Bearer", expires_in: 3600 }))
  end

  test "nothing configured: every integration reports not configured, no request, no event" do
    results = GoogleIntegration::Check.run
    assert_equal [ :off ] * 4, results.map(&:status)
    assert_equal [ "not configured" ] * 4, results.map(&:message)
    assert_equal 0, GoogleIntegration::Event.count
  end

  test "login: invalid_grant means the client is accepted; invalid_client means it is refused" do
    stub_request(:post, GoogleStubs::TOKEN_URL).with(body: hash_including("code" => "glassbox-check-not-a-real-code", "client_id" => "uji-id"))
                                               .to_return(json_response({ error: "invalid_grant" }, status: 400))
    ok = with_env(LOGIN_ENV) { GoogleIntegration::Check.run.first }
    assert_equal [ :login, :ok ], [ ok.integration, ok.status ]
    assert_equal "ok", GoogleIntegration::Event.latest(:login).outcome

    stub_request(:post, GoogleStubs::TOKEN_URL).to_return(json_response({ error: "invalid_client", error_description: "The OAuth client was not found." }, status: 401))
    bad = with_env(LOGIN_ENV) { GoogleIntegration::Check.run.first }
    assert_equal :failed, bad.status
    assert_equal "Google refused the client ID or secret (invalid_client)", bad.message
    assert_equal "failed", GoogleIntegration::Event.latest(:login).outcome
    refute_includes GoogleIntegration::Event.latest(:login).message.to_s, "uji-secret"

    stub_request(:post, GoogleStubs::TOKEN_URL).to_return(status: 502, body: "<html>proxy</html>")
    odd = with_env(LOGIN_ENV) { GoogleIntegration::Check.run.first }
    assert_equal :failed, odd.status, "a body that is not Google's JSON is not a pass"
  end

  test "mail: SMTP login with STARTTLS, then quit; a refused app password is a failure" do
    calls = []
    fake = Object.new
    fake.define_singleton_method(:open_timeout=) { |_| }
    fake.define_singleton_method(:read_timeout=) { |_| }
    fake.define_singleton_method(:enable_starttls) { calls << :starttls }
    fake.define_singleton_method(:start) { |domain, user, _pass, auth, &blk| calls << [ :start, domain, user, auth ]; blk&.call }
    env = { "GOOGLE_MAIL_USERNAME" => "hr@uji.example", "GOOGLE_MAIL_APP_PASSWORD" => "uji-app-pass" }
    result = Net::SMTP.stub(:new, ->(host, port) { calls << [ host, port ]; fake }) { with_env(env) { GoogleIntegration::Check.run[1] } }
    assert_equal :ok, result.status
    assert_equal [ [ "smtp.gmail.com", 587 ], :starttls, [ :start, "uji.example", "hr@uji.example", :plain ] ], calls

    fake.define_singleton_method(:start) { |*| raise Net::SMTPAuthenticationError.new("535-5.7.8 Username and Password not accepted") }
    refused = Net::SMTP.stub(:new, ->(*) { fake }) { with_env(env) { GoogleIntegration::Check.run[1] } }
    assert_equal :failed, refused.status
    assert_match "Net::SMTPAuthenticationError", refused.message
  end

  test "storage: the bucket's region must match GOOGLE_STORAGE_REGION (UU PDP)" do
    stub_any_token!
    stub_request(:get, BUCKET_URL).with(query: hash_including({}))
                                  .to_return(json_response({ name: "glassbox-uji-bucket", location: "ASIA-SOUTHEAST2",
                                                             iamConfiguration: { publicAccessPrevention: "enforced" } }))
    stub_request(:get, BUCKET_URL).to_return(json_response({ name: "glassbox-uji-bucket", location: "ASIA-SOUTHEAST2",
                                                             iamConfiguration: { publicAccessPrevention: "enforced" } }))
    ok = with_env(storage_env) { GoogleIntegration::Check.run[2] }
    assert_equal :ok, ok.status, ok.message
    assert_match "asia-southeast2", ok.message

    wrong = with_env(storage_env(region: "asia-southeast1")) { GoogleIntegration::Check.run[2] }
    assert_equal :failed, wrong.status
    assert_equal "bucket is in asia-southeast2, not asia-southeast1 (UU PDP: move it before use)", wrong.message
  end

  test "calendar: reads the calendar's metadata as the impersonated user" do
    stub_google_token!
    got = stub_request(:get, "https://www.googleapis.com/calendar/v3/calendars/jadwal@uji.example").to_return(json_response({ id: "jadwal@uji.example" }))
    result = with_calendar_env { GoogleIntegration::Check.run[3] }
    assert_equal :ok, result.status, result.message
    assert_requested got, times: 1
    assert_requested(:post, GoogleStubs::SERVICE_ACCOUNT_TOKEN_URL) { |req| req.body.include?("assertion=") }
  end

  test "GLASSBOX_STORAGE_SERVICE=google without bucket and service account refuses to boot" do
    with_env("GLASSBOX_STORAGE_SERVICE" => "google") do
      error = assert_raises(Glassbox::Settings::Invalid) { GoogleIntegration::Config.validate_storage! }
      assert_match "GOOGLE_STORAGE_BUCKET", error.message
    end
    with_env(storage_env.merge("GLASSBOX_STORAGE_SERVICE" => "google")) { assert GoogleIntegration::Config.validate_storage! }
    assert GoogleIntegration::Config.validate_storage!, "control: local needs nothing"
    assert_includes Glassbox::Settings.problems("TENANCY" => "single", "GLASSBOX_STORAGE_SERVICE" => "s3").join, "GLASSBOX_STORAGE_SERVICE"
  end

  test "config/storage.yml builds a private google service from the service account, and nothing while unset" do
    configs = with_env(storage_env) { ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml")) }
    google = configs.fetch("google")
    assert_equal [ "GCS", "glassbox-uji-bucket", "glassbox-uji" ], [ google["service"], google["bucket"], google["project"] ]
    assert_equal "glassbox-uji@glassbox-uji.iam.gserviceaccount.com", google.dig("credentials", "client_email")
    assert_equal "private, max-age=0", google["cache_control"]
    assert_nil google["public"], "the bucket is never served publicly"

    empty = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))["google"]
    assert_equal({}, empty["credentials"])
    assert_equal :local, Rails.application.config.active_storage.service.then { |s| s == :test ? :local : s }
  end

  test "Gmail SMTP is switched on only in production with mailbox and app password" do
    mailer = Class.new(ActionMailer::Base)
    env = { "GOOGLE_MAIL_USERNAME" => "hr@uji.example", "GOOGLE_MAIL_APP_PASSWORD" => "uji-app-pass" }
    with_env(env) { refute GoogleIntegration::Config.apply_mail!(mailer, production: false) }
    refute GoogleIntegration::Config.apply_mail!(mailer, production: true), "no credentials, no switch"
    with_env(env) { assert GoogleIntegration::Config.apply_mail!(mailer, production: true) }
    assert_equal :smtp, mailer.delivery_method
    settings = mailer.smtp_settings
    assert_equal [ "smtp.gmail.com", 587, true, :plain, "hr@uji.example" ],
                 settings.values_at(:address, :port, :enable_starttls, :authentication, :user_name)
    assert_equal :test, ActionMailer::Base.delivery_method, "the real mailer in tests is untouched"
  end

  test "the sender and reply-to come from MAIL_FROM and MAIL_REPLY_TO; the fallback is unchanged" do
    user = staff_user("admin")
    mail = PasswordsMailer.reset(user)
    assert_equal [ "from@example.com" ], mail.from
    assert_nil mail.reply_to

    mail = with_env("MAIL_FROM" => "rekrutmen@uji.example", "MAIL_REPLY_TO" => "hr@uji.example") do
      PasswordsMailer.reset(user).tap(&:message)
    end
    assert_equal [ "rekrutmen@uji.example" ], mail.from
    assert_equal [ "hr@uji.example" ], mail.reply_to
  end

  test "every Google key GoogleIntegration::Config reads is declared in the settings registry" do
    declared = Glassbox::Settings::ENV_KEYS.keys
    missing = GoogleIntegration::Config::KEYS.values + %w[GLASSBOX_STORAGE_SERVICE MAIL_FROM MAIL_REPLY_TO DRY_RUN] - declared
    assert_empty missing
    assert_equal 10, GoogleIntegration::Config::KEYS.size, "the scan read the key table"
  end

  # A text check, not a behaviour test: production.rb cannot be loaded inside the test environment.
  # It guards the one-line fix that made email links follow APP_HOST instead of "example.com".
  test "production email links are built from APP_HOST" do
    production = Rails.root.join("config/environments/production.rb").read
    assert_match(/default_url_options = \{ host: ENV\.fetch\("APP_HOST", "example\.com"\), protocol: "https" \}/, production)
  end

  # F-10-01 follow-up: an uncaught boot error prints its `cause` under "Caused by", and the cause
  # of a JSON error is the JSON error that quotes the key. Both the message and the cause chain must
  # be free of the key.
  test "a malformed service-account key raises without the key in the message or the cause chain" do
    broken = %({"private_key":"-----BEGIN PRIVATE KEY-----\nGEHEIM-UJI\n-----END PRIVATE KEY-----"})
    error = assert_raises(Glassbox::GoogleKey::Invalid) { Glassbox::GoogleKey.parse(broken) }
    refute_includes error.message, "GEHEIM-UJI"
    assert_nil error.cause, "a cause would be printed under 'Caused by' at boot"
    boot = with_env("GLASSBOX_STORAGE_SERVICE" => "google", "GOOGLE_STORAGE_BUCKET" => "b", "GOOGLE_SERVICE_ACCOUNT_JSON" => broken) do
      assert_raises(Glassbox::Settings::Invalid) { GoogleIntegration::Config.validate_storage! }
    end
    refute_includes boot.full_message, "GEHEIM-UJI"
    assert_nil boot.cause
    assert_equal "x [key redacted] y", Glassbox::GoogleKey.redact("x -----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY----- y")
  end
end
