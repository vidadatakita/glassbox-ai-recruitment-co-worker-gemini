# D52: every Google call in the tests is stubbed, and WebMock refuses any real outgoing HTTP
# request in the WHOLE suite (it patches Net::HTTP process-wide once loaded). Localhost stays
# allowed so system tests and their browser driver keep working. A test that needs Google stubs
# the exact request; an unstubbed request raises WebMock::NetConnectNotAllowedError, which is the
# guard that "no test ever makes a real Google call".
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)

module GoogleStubs
  TOKEN_URL = "https://oauth2.googleapis.com/token".freeze

  # Sets ENV keys for the block and restores them afterwards (tests run in forked processes, so
  # ENV is per worker). Every Google value used in tests is obviously fake.
  def with_env(values)
    before = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    before.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # A service-account key file with a key generated at RUN time: no private key is ever committed,
  # not even a test one (secret scanners and the house rule both say so).
  def fake_service_account_json
    @@fake_service_account_json ||= begin # rubocop:disable Style/ClassVars -- one RSA key per test process is enough
      key = OpenSSL::PKey::RSA.new(2048)
      { "type" => "service_account", "project_id" => "glassbox-uji", "private_key_id" => "uji",
        "private_key" => key.to_pem, "client_email" => "glassbox-uji@glassbox-uji.iam.gserviceaccount.com",
        "client_id" => "1", "token_uri" => TOKEN_URL }.to_json
    end
  end

  CALENDAR_ENV = { "GOOGLE_CALENDAR_ID" => "jadwal@uji.example", "GOOGLE_CALENDAR_IMPERSONATE" => "admin@uji.example" }.freeze

  def with_calendar_env(&)
    with_env(CALENDAR_ENV.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => fake_service_account_json), &)
  end

  # googleauth exchanges the service account's signed JWT here (not at the key file's token_uri).
  SERVICE_ACCOUNT_TOKEN_URL = "https://www.googleapis.com/oauth2/v4/token".freeze

  # The service account's JWT-bearer token exchange.
  def stub_google_token!(status: 200, body: { access_token: "uji-token", token_type: "Bearer", expires_in: 3600 })
    stub_request(:post, SERVICE_ACCOUNT_TOKEN_URL).to_return(status:, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def calendar_events_url = "https://www.googleapis.com/calendar/v3/calendars/#{CALENDAR_ENV['GOOGLE_CALENDAR_ID']}/events"

  def json_response(body, status: 200) = { status:, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end

ActiveSupport.on_load(:active_support_test_case) { include GoogleStubs }
ActiveSupport.on_load(:action_dispatch_integration_test) { include GoogleStubs }
