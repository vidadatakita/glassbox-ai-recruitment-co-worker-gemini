# A5 (Cup rule "works without login"): the "Try the demo" door. GET /demo shows what the demo
# workspace holds and three doors, one per role the demo needs (HR owner decides, reviewer releases
# text to Gemini, owner agrees the salary). POST /demo signs the visitor into that role's seeded
# account and sends them to the staff screens. No credentials are asked, no password travels.
#
# Only in DEMO_MODE=1 (settings registry). On any other install every action here answers 404, so
# a real client server never carries an open door: the check runs before anything else, and the
# routes are only drawn in demo mode as well (config/routes.rb), belt and braces.
#
# Sign-in is logged like every other one (SignInEvent, auth_method "demo"), so the audit trail of a
# demo session names the demo account and the time, never a visitor's identity (none is known).
class DemoSessionsController < ApplicationController
  allow_browser versions: :modern
  layout "auth"
  allow_unauthenticated_access
  before_action :demo_mode_required
  rate_limit to: 30, within: 3.minutes, only: :create, with: -> { redirect_to demo_path, alert: "Too many attempts. Try again in a few minutes." }

  # Door => role of the seeded account it opens. The seed creates one account per role.
  DOORS = {
    "hr_admin" => { role: "hr_admin", title: "HR Admin", does: "Writes the brief and the ad with AI help, opens the portal, starts the screening, and takes every Continue / Do not continue decision with a written reason." },
    "hr_manager" => { role: "hr_manager", title: "HR Manager", does: "Reads each redacted CV and presses Send to Gemini, scores the technical test, and agrees the salary. The AI never sees money." },
    "superadmin" => { role: "superadmin", title: "Superadmin", does: "Can do every step, from the job ad to the system settings, to walk the whole flow alone." }
  }.freeze

  def show
    @doors = DOORS
    @apply_jobs = Job.where(brief_status: "complete").order(:id).limit(3)
  end

  def create
    door = DOORS.fetch(params[:role].to_s) { return redirect_to(demo_path, alert: "Choose one of the three doors.") }
    user = User.where(role: door[:role]).order(:id).first
    return redirect_to(demo_path, alert: "The demo workspace is not seeded yet. Try again in a minute.") if user.nil?

    reset_session
    start_new_session_for user
    SignInEvent.record!(request:, auth_method: "demo", outcome: "success", user:)
    redirect_to staff_root_path, notice: "You are in the demo as #{user.name} (#{door[:title]}). Everything here is invented data and resets every night."
  end

  private

  def demo_mode_required
    raise ActionController::RoutingError, "Not Found" unless Glassbox::Settings.demo_mode?
  end
end
