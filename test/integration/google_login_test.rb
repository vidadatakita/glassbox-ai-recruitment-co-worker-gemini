require "test_helper"

# D52 (1): staff "Sign in with Google". Only a pre-registered user, matched case-insensitively,
# with a Google-verified email (and the configured Workspace domain, when set) gets a Session.
# Anyone else is refused in Bahasa, and no User or Session is created. The button exists only
# while a client id AND secret are configured; initiation is POST-only with a CSRF token.
class GoogleLoginTest < ActionDispatch::IntegrationTest
  LOGIN_ENV = { "GOOGLE_OAUTH_CLIENT_ID" => "uji-client-id.apps.googleusercontent.com",
                "GOOGLE_OAUTH_CLIENT_SECRET" => "uji-client-secret-JANGAN-TAMPIL" }.freeze

  setup do
    # Rate-limit counters live in the controllers' memory cache and survive between test classes in
    # one worker. The engine's flood tests (31 GETs to /auth/failure, 11 callbacks) left the counters
    # full, so a later test here was refused by the limiter and wrote no sign_in_events row:
    # "undefined method 'reason' for nil" (team lead 19:0x; reproduced with --seed 12 and 14).
    GoogleSessionsController.cache_store.clear
    SessionsController.cache_store.clear
    @hr = staff_user("hr_pic", email: "dewi@uji.example")
    OmniAuth.config.test_mode = false
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def google_auth(email:, verified: true, hd: nil)
    OmniAuth::AuthHash.new(provider: "google_oauth2", uid: "uji-uid",
                           info: { email:, name: "Uji" },
                           credentials: { token: "uji-access-token-RAHASIA" },
                           extra: { id_info: { "email" => email, "email_verified" => verified, "hd" => hd }.compact,
                                    raw_info: { "email" => email, "email_verified" => verified, "hd" => hd }.compact })
  end

  def callback_with(auth, env: LOGIN_ENV)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = auth
    with_env(env) { get "/auth/google_oauth2/callback" }
  end

  test "no button and no Google route while the client id or secret is missing" do
    get new_session_path
    assert_response :success
    assert_no_match "Sign in with Google", response.body

    with_env("GOOGLE_OAUTH_CLIENT_ID" => "uji-client-id-only") { get new_session_path }
    assert_no_match "Sign in with Google", response.body, "a client id without a secret is not configured"

    post "/auth/google_oauth2"
    assert_redirected_to new_session_path
    assert_equal "Sign in with Google is not set up. Please sign in with email and password.", flash[:alert]
  end

  test "with credentials the button is its own POST form, after (not inside) the password form" do
    with_env(LOGIN_ENV) { get new_session_path }
    page = Nokogiri::HTML(response.body)
    forms = page.css("form")
    assert_equal 2, forms.size, "password form + Google form"
    assert_empty page.css("form form"), "hard rule: no form inside a form"
    google = forms.find { |f| f["action"] == "/auth/google_oauth2" }
    assert google, "the Google form posts to /auth/google_oauth2"
    assert_equal "post", google["method"]
    assert_match "Sign in with Google", google.text
    assert_equal 1, page.css("input[name=password]").size, "password login stays"
    assert_no_match "uji-client-secret-JANGAN-TAMPIL", response.body
  end

  test "the request phase is POST-only and needs the authenticity token" do
    with_env(LOGIN_ENV) do
      get "/auth/google_oauth2"
      assert_response :not_found, "GET must never start a Google login (login CSRF)"

      ActionController::Base.allow_forgery_protection = true
      begin
        post "/auth/google_oauth2"
        assert_redirected_to %r{/auth/failure\?message=ActionController%3A%3AInvalidAuthenticityToken}, "POST without the token is refused"
        assert_no_difference -> { GoogleIntegration::Event.count } do
          follow_redirect!
        end
        assert_equal "provider_authenticity_error", SignInEvent.order(:id).last.reason, "a CSRF refusal is the user's side, not Google's"

        get new_session_path
        token = Nokogiri::HTML(response.body).at_css("form[action='/auth/google_oauth2'] input[name=authenticity_token]")["value"]
        post "/auth/google_oauth2", params: { authenticity_token: token }
        assert_response :redirect
        location = URI(response.location)
        assert_equal "accounts.google.com", location.host, "control: with the token, OmniAuth sends the user to Google"
        assert_includes location.query, "client_id=uji-client-id.apps.googleusercontent.com"
      ensure
        ActionController::Base.allow_forgery_protection = false
      end
    end
  end

  test "a registered user signs in with a Google email in any case, and the sign-in is logged without tokens" do
    assert_difference -> { Session.count } => 1, -> { User.count } => 0 do
      callback_with(google_auth(email: "DEWI@Uji.Example"))
    end
    assert_redirected_to root_url
    session_row = Session.order(:id).last
    assert_equal @hr, session_row.user
    event = SignInEvent.order(:id).last
    assert_equal [ "google", "success", @hr.id ], [ event.auth_method, event.outcome, event.user_id ]
    refute_includes event.attributes.values.join(" "), "uji-access-token-RAHASIA"

    get staff_root_path
    assert_response :success, "the Google session opens the staff screens"
  end

  test "an unknown email is refused in Bahasa: no account, no session, only the domain is logged" do
    assert_no_difference -> { Session.count } do
      assert_no_difference -> { User.count } do
        callback_with(google_auth(email: "orang.asing@gmail.com"))
      end
    end
    assert_redirected_to new_session_path
    assert_equal GoogleSessionsController::REFUSED, flash[:alert]
    event = SignInEvent.order(:id).last
    assert_equal [ "refused", "unknown_email", "gmail.com", nil ], [ event.outcome, event.reason, event.email_domain, event.user_id ]
    refute_includes event.attributes.values.join(" "), "orang.asing"
  end

  test "a candidate's Google account is refused: candidates are not users" do
    Candidate.create!(name: "Rina Pratiwi", email: "rina@uji.example", phone: "081234567890")
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "rina@uji.example"))
    end
    assert_equal GoogleSessionsController::REFUSED, flash[:alert]
  end

  test "an email Google has not verified is refused even when it matches a staff address" do
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dewi@uji.example", verified: false))
    end
    assert_equal "email_unverified", SignInEvent.order(:id).last.reason
  end

  test "with a Workspace domain set, the ID-token hd claim must match it" do
    domain_env = LOGIN_ENV.merge("GOOGLE_LOGIN_HOSTED_DOMAIN" => "uji.example")
    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dewi@uji.example", hd: nil), env: domain_env)
    end
    assert_equal "Use a uji.example Google account to sign in to GlassBox.", flash[:alert]
    assert_equal "hosted_domain", SignInEvent.order(:id).last.reason

    assert_no_difference -> { Session.count } do
      callback_with(google_auth(email: "dewi@uji.example", hd: "lain.example"), env: domain_env)
    end

    assert_difference -> { Session.count } => 1 do
      callback_with(google_auth(email: "dewi@uji.example", hd: "uji.example"), env: domain_env)
    end
  end

  test "a provider error is recorded for Pengaturan Sistem; a user cancelling is not" do
    assert_difference -> { GoogleIntegration::Event.where(integration: "login", outcome: "failed").count } => 1 do
      get "/auth/failure", params: { message: "invalid_credentials" }
    end
    assert_redirected_to new_session_path
    assert_difference -> { GoogleIntegration::Event.count } => 0 do
      get "/auth/failure", params: { message: "access_denied" }
    end
    assert_equal %w[provider_invalid_credentials provider_access_denied], SignInEvent.order(:id).last(2).map(&:reason)
  end

  test "a password sign-in is logged too" do
    post session_path, params: { email_address: "dewi@uji.example", password: "rahasia-uji-123" }
    assert_redirected_to root_url
    event = SignInEvent.order(:id).last
    assert_equal [ "password", "success", @hr.id ], [ event.auth_method, event.outcome, event.user_id ]
  end

  # Session fixation (security review 18:3x): the Rails session that existed BEFORE the Google
  # callback must not be the one in use after it, and the page the user was going to survives.
  test "the callback starts a fresh Rails session and still returns to the page asked for" do
    get staff_jobs_path
    assert_redirected_to new_session_path
    planted_id = session.id.to_s
    assert planted_id.present?, "control: a session exists before the callback"
    planted_auth_cookie = cookies["session_id"]

    callback_with(google_auth(email: "dewi@uji.example"))
    assert_redirected_to staff_jobs_url, "the return URL survives reset_session"
    refute_equal planted_id, session.id.to_s, "the pre-login Rails session id must not survive the login"
    refute_equal planted_auth_cookie, cookies["session_id"], "a new signed login cookie is issued"
    assert_nil session[:return_to_after_authenticating], "nothing from the old session is carried over"
  end

  # Same rule for the password login (feature 02 finding, fixed under the team lead's 18:5x approval).
  test "the password login starts a fresh Rails session and still returns to the page asked for" do
    get staff_jobs_path
    assert_redirected_to new_session_path
    planted_id = session.id.to_s
    assert planted_id.present?, "control: a session exists before login"

    post session_path, params: { email_address: "dewi@uji.example", password: "rahasia-uji-123" }
    assert_redirected_to staff_jobs_url, "the return URL survives reset_session"
    refute_equal planted_id, session.id.to_s, "the pre-login Rails session id must not survive the login"
    assert_nil session[:return_to_after_authenticating]
    get staff_jobs_path
    assert_response :success, "control: the new session is signed in"
  end
end
