# D52 (1): staff sign-in with a Google account. Password login (SessionsController) stays as it
# is; this only adds a second way in to the SAME Session model.
#
# Rules, each checked here on the server, never trusted from the browser:
# - only a PRE-REGISTERED staff user may sign in: the Google email must equal a User's
#   email_address (case-insensitive; User normalises to lower case). No account is ever created.
# - Google must say the email is verified (email_verified), otherwise anyone could register an
#   unverified Google account under a staff address.
# - when GOOGLE_LOGIN_HOSTED_DOMAIN is set, the ID token's `hd` claim must equal it. The `hd`
#   request parameter is only a hint to Google's chooser; the claim is the proof.
# Every attempt is logged in sign_in_events (who, how, when; for a refusal the email domain only).
# No token, code or full refused address is stored or logged.
class GoogleSessionsController < ApplicationController
  layout "auth"
  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_session_path, alert: "Too many attempts. Try again in a few minutes." }
  # /auth/failure needs no login (OmniAuth redirects there) and writes to append-only tables, so it
  # is bounded too, with its own counter (test engine F-10-03: 31 anonymous GETs wrote 31 rows and
  # faked "Gagal terakhir"). A limited request writes nothing.
  rate_limit to: 10, within: 3.minutes, only: :failure, name: "google-failure",
             with: -> { redirect_to new_session_path, alert: "Too many attempts. Try again in a few minutes." }

  REFUSED = "This Google account is not registered as a GlassBox user. Contact the admin, or sign in with email and password.".freeze

  # GET/POST /auth/google_oauth2/callback, after OmniAuth has verified state and exchanged the code.
  def create
    auth = request.env["omniauth.auth"]
    return refuse!(nil, "no_auth_hash", "Sign in with Google failed. Please try again.") unless auth

    email = auth.dig("info", "email").to_s.strip.downcase
    claims = auth.dig("extra", "id_info") || {}
    raw = auth.dig("extra", "raw_info") || {}
    verified = [ claims["email_verified"], raw["email_verified"], auth.dig("info", "email_verified") ].any? { |v| v == true || v == "true" }

    return refuse!(email, "email_unverified", REFUSED) if email.blank? || !verified

    domain = GoogleIntegration::Config.hosted_domain
    if domain && (claims["hd"] || raw["hd"]).to_s.downcase != domain
      return refuse!(email, "hosted_domain", "Use a #{domain} Google account to sign in to GlassBox.")
    end

    user = User.find_by(email_address: email)
    return refuse!(email, "unknown_email", REFUSED) unless user

    # A fresh Rails session after login (session fixation); keep only where the user was going.
    return_to = after_authentication_url
    reset_session
    start_new_session_for user
    SignInEvent.record!(request:, auth_method: "google", outcome: "success", user:)
    redirect_to return_to
  end

  # GET /auth/failure?message=... (OmniAuth on_failure). The cause from Google is recorded for
  # Pengaturan Sistem, because a wrong client secret otherwise looks to the operator like a broken
  # button. csrf_detected / access_denied are user-side and are not integration failures.
  def failure
    raw = params[:message].to_s
    # omniauth-rails_csrf_protection reports a missing token as the exception NAME
    # (ActionController::InvalidAuthenticityToken), not as a code.
    code = raw.match?(/authenticity/i) ? "authenticity_error" : raw.downcase.gsub(/[^a-z_]/, "").first(60).presence || "unknown"
    unless %w[csrf_detected access_denied authenticity_error].include?(code)
      GoogleIntegration::Event.record!(:login, source: :login, message: "Google refused the login: #{code}",
                                       error: RuntimeError.new("omniauth #{code}"))
    end
    SignInEvent.record!(request:, auth_method: "google", outcome: "refused", reason: "provider_#{code}")
    redirect_to new_session_path, alert: "Sign in with Google failed. Please try again, or sign in with email and password."
  end

  # POST /auth/google_oauth2 while Google login is NOT configured (the middleware lets it through).
  def unavailable
    redirect_to new_session_path, alert: "Sign in with Google is not set up. Please sign in with email and password."
  end

  private

  def refuse!(email, reason, message)
    SignInEvent.record!(request:, auth_method: "google", outcome: "refused", reason:, email:)
    redirect_to new_session_path, alert: message
  end
end
