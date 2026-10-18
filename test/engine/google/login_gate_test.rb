require "test_helper"

# Test engine, feature 10 (D52 (1)): how does "Masuk dengan Google" break?
# Each test names the mutant it must kill. Every Google answer
# is an OmniAuth mock; no request leaves the process (WebMock, test/support/google_stubs.rb).
#
# Claim -> mutant -> test that goes red:
# - "a fresh Rails session after login (session fixation)" -> delete reset_session -> test G-L1
# - "only a pre-registered user" -> find_by replaced by first -> builder test + G-L3 lookalike
# - "the claim is the proof" (hd) -> hd check removed -> builder test + G-L4
# - "rate limited" -> rate_limit removed -> G-L6
# - "no token, code or full refused address is logged" -> G-L5 (reads the Rails log)
class GoogleEngineLoginGateTest < ActionDispatch::IntegrationTest
  LOGIN_ENV = { "GOOGLE_OAUTH_CLIENT_ID" => "uji-client-id.apps.googleusercontent.com",
                "GOOGLE_OAUTH_CLIENT_SECRET" => "uji-client-secret-ENGINE" }.freeze

  setup do
    @hr = staff_user("hr_pic", email: "dewi@uji.example")
    GoogleSessionsController.cache_store.clear # rate-limit counters (memory store in test)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def google_auth(email:, verified: true, hd: nil, info_hd: nil)
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "uji-uid",
                           info: { email:, name: "Uji", hd: info_hd }.compact,
                           credentials: { token: "ENGINE-ACCESS-TOKEN-RAHASIA", refresh_token: "ENGINE-REFRESH-RAHASIA" },
                           extra: { id_info: { "email" => email, "email_verified" => verified, "hd" => hd }.compact,
                                    raw_info: { "email" => email, "email_verified" => verified, "hd" => hd }.compact })
  end

  def callback_with(auth, env: LOGIN_ENV, path: "/auth/google_oauth2/callback")
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = auth
    with_env(env) { get path }
  end

  # G-L1. Kills: reset_session deleted.
  test "a Google sign-in starts a NEW Rails session id (session fixation), and keeps where the user was going" do
    get staff_jobs_path # unauthenticated: stores return_to and creates the pre-login session
    assert_redirected_to new_session_path
    before_id = session.id.to_s
    assert before_id.present?, "control: a pre-login session exists"

    callback_with(google_auth(email: "dewi@uji.example"))
    assert_redirected_to staff_jobs_url, "return_to survives the reset"
    refute_equal before_id, session.id.to_s, "the session id issued before login must not survive the login"
  end

  # G-L2. Whitespace and case are normalised; an address that only LOOKS the same is not.
  test "' DEWI@Uji.Example ' signs in; a unicode lookalike of the same address is refused" do
    assert_difference -> { Session.count } => 1 do
      callback_with(google_auth(email: " DEWI@Uji.Example "))
    end

    # U+0435 (Cyrillic small ie) in place of the Latin e.
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dеwi@uji.example"))
    end
    assert_equal "unknown_email", SignInEvent.order(:id).last.reason
  end

  # G-L3. Every staff role can use Google, and the session carries THAT user's role only.
  test "a reviewer signing in with Google is a reviewer: Settings stays closed" do
    reviewer = staff_user("reviewer", email: "budi@uji.example")
    callback_with(google_auth(email: "budi@uji.example"))
    assert_equal reviewer, Session.order(:id).last.user
    get staff_settings_path
    assert_redirected_to staff_jobs_path
  end

  # G-L4. The hd that counts is the ID-token claim, not info.hd (which a mock or a future mapping
  # could fill from a request parameter).
  test "with a Workspace domain set, info.hd alone does not satisfy it" do
    env = LOGIN_ENV.merge("GOOGLE_LOGIN_HOSTED_DOMAIN" => "UJI.example")
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dewi@uji.example", hd: nil, info_hd: "uji.example"), env:)
    end
    assert_equal "hosted_domain", SignInEvent.order(:id).last.reason

    assert_difference(-> { Session.count }, 1, "control: the claim in any case is accepted") do
      callback_with(google_auth(email: "dewi@uji.example", hd: "Uji.Example"), env:)
    end
  end

  # G-L5. Reads what the Rails log actually received during a success and a refusal.
  test "the Rails log never holds the access token, the code, or a refused full address" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = :debug
    saved = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    begin
      Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
      callback_with(google_auth(email: "dewi@uji.example"), path: "/auth/google_oauth2/callback?code=ENGINE-AUTH-CODE&state=s1")
      callback_with(google_auth(email: "orang.asing.rahasia@gmail.com"), path: "/auth/google_oauth2/callback?code=ENGINE-AUTH-CODE&state=s2")
    ensure
      Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = saved
    end
    log = io.string
    assert_match "GoogleSessionsController#create", log, "control: the log captured the requests"
    refute_includes log, "ENGINE-ACCESS-TOKEN-RAHASIA"
    refute_includes log, "ENGINE-REFRESH-RAHASIA"
    refute_includes log, "ENGINE-AUTH-CODE"
    refute_includes log, "orang.asing.rahasia"
    refute_includes log, "dewi@uji.example", "even a known staff address is filtered (ONP-19)"
  end

  # G-L6. Kills: rate_limit removed from the controller.
  test "the callback is rate limited: the 11th attempt within 3 minutes gets no session" do
    10.times { callback_with(google_auth(email: "orang.asing@gmail.com")) }
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dewi@uji.example"))
    end
    assert_equal "Too many attempts. Try again in a few minutes.", flash[:alert]
  end

  # G-L7 (FINDING F-10-03). GET /auth/failure is unauthenticated by necessity (OmniAuth redirects
  # there), but every hit writes a FAILED login event into an append-only table and flips
  # Settings to "Last failed". Nothing limits it, so a stranger with a browser can
  # fake an integration outage and grow an undeletable table without bound.
  test "a stranger cannot flood /auth/failure: the endpoint is rate limited like the callback" do
    assert_difference(-> { GoogleIntegration::Event.count }, 1, "control: one provider error is recorded") do
      get "/auth/failure", params: { message: "invalid_credentials" }
    end
    30.times { get "/auth/failure", params: { message: "invalid_credentials" } }
    assert_operator GoogleIntegration::Event.where(integration: "login").count, :<=, 10,
                    "unauthenticated GETs must not write unbounded failure rows"
  end
end
