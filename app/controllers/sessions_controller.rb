class SessionsController < ApplicationController
  allow_browser versions: :modern
  layout "auth"
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Too many attempts. Try again in a few minutes." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      # A fresh Rails session after login (session fixation), keeping only where the user was going;
      # same order as GoogleSessionsController (team lead 18:5x). Reading the URL AFTER the reset
      # would always send the user to the root.
      return_to = after_authentication_url
      reset_session
      start_new_session_for user
      # D52: every staff sign-in is logged (who, how, when). Failed password attempts are not
      # logged here: the typed address may be anyone's, and the rate limit already bounds them.
      SignInEvent.record!(request:, auth_method: "password", outcome: "success", user:)
      redirect_to return_to
    else
      redirect_to new_session_path, alert: "Email or password does not match."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
