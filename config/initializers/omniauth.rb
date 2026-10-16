# D52 (1): staff "Masuk dengan Google" (OmniAuth + Google OAuth2). Candidates never use it: they
# have no User row, so a candidate's Google account is refused like any unknown email.
#
# The middleware is always installed, but it acts ONLY while Google login is configured:
# - request_path is a proc that matches /auth/google_oauth2 only when a client id AND secret are
#   set. When they are not, the POST falls through to the Rails route
#   GoogleSessionsController#unavailable, which says "belum diatur" instead of sending the user
#   to a Google error page.
# - the client id, secret and hosted domain are read PER REQUEST in the setup lambda, not at boot,
#   so setting the credentials needs only a restart of the app, and tests can switch them.
#
# Initiation is POST-only with a Rails authenticity token: OmniAuth 2 allows only POST by default
# and omniauth-rails_csrf_protection checks the token (CVE-2015-9284, login CSRF). Do not add :get
# to allowed_request_methods; a GET link would reopen that hole.
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, nil, nil,
           name: "google_oauth2",
           scope: "openid,email,profile",
           prompt: "select_account",
           request_path: ->(env) {
             GoogleIntegration::Config.login_configured? && env["PATH_INFO"].to_s.casecmp?("/auth/google_oauth2")
           },
           setup: ->(env) {
             options = env["omniauth.strategy"].options
             options[:client_id] = GoogleIntegration::Config.oauth_client_id
             options[:client_secret] = GoogleIntegration::Config.oauth_client_secret
             # A hint to Google's account chooser AND enforced by the gem on the callback
             # (verify_hd). GoogleSessionsController checks the ID-token claim again on its own.
             hd = GoogleIntegration::Config.hosted_domain
             options[:hd] = hd if hd
           }
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.logger = Rails.logger
# A failure on Google's side (wrong client secret, cancelled consent, state mismatch) lands on
# GET /auth/failure?message=<code>; the controller records it and shows a Bahasa message.
OmniAuth.config.on_failure = ->(env) { OmniAuth::FailureEndpoint.new(env).redirect_to_failure }
