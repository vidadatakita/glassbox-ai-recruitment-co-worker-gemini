require "test_helper"

# A4 (16 Oct 2026): on the public Cup demo (DEMO_MODE=1) only the twelve demo steps are routed. The
# routes are drawn from the flag at boot, so this test redraws them under each value and asserts on
# the result, then restores the suite's own routes. Control: every cut route IS present without the
# flag, so a typo in a path here fails on the control, not silently.
class DemoRoutesTest < ActiveSupport::TestCase
  CUT_IN_DEMO = [
    [:get, "/passwords/new"], [:post, "/auth/google_oauth2"], [:get, "/auth/failure"],
    [:post, "/staff/applications/1/salary/ai-advice"], [:post, "/staff/applications/1/letter/draft"], [:post, "/staff/applications/1/letter"],
    [:post, "/staff/participations/1/appointments"], [:post, "/staff/participations/1/score"], [:post, "/staff/appointments/1/calendar"],
    # Settings are READ-ONLY on the demo (18 Oct 2026): the page shows, the saving routes do not exist.
    [:patch, "/staff/settings"], [:post, "/staff/settings/consent"]
  ].freeze
  KEPT_IN_DEMO = [
    # The work queue and the read-only settings page are on the demo since 18 Oct 2026 (the team lead).
    [:get, "/staff/work_queue"], [:get, "/staff/settings"],
    [:get, "/demo"], [:get, "/session/new"], [:get, "/apply/abc"], [:get, "/status/tok"], [:get, "/status/tok/technical-test"],
    [:get, "/score/tok"], [:get, "/staff/jobs/1/brief"], [:get, "/staff/jobs/1/ad"], [:post, "/staff/jobs/1/portal/open"],
    [:get, "/staff/jobs/1/ai-review"], [:get, "/staff/jobs/1/screening/review"], [:get, "/staff/jobs/1/screening-report"],
    [:get, "/staff/applications/1"], [:post, "/staff/participations/1/choice"], [:post, "/staff/participations/1/assessor"],
    [:post, "/staff/applications/1/salary"], [:post, "/staff/applications/1/offers"], [:get, "/staff/impact"],
    [:get, "/staff/ask"], [:post, "/staff/ask"]
  ].freeze

  def redraw(demo_mode)
    with_env("DEMO_MODE" => demo_mode) { Rails.application.reload_routes! }
  end

  teardown { redraw(nil) }

  def routed?(verb, path)
    Rails.application.routes.recognize_path(path, method: verb)
    true
  rescue ActionController::RoutingError
    false
  end

  test "control: without the flag every route of the base is drawn, and the demo door is not" do
    redraw(nil)
    CUT_IN_DEMO.each { |verb, path| assert routed?(verb, path), "#{verb.upcase} #{path} should exist on a normal install" }
    refute routed?(:get, "/demo"), "the demo door must not exist on a normal install"
  end

  test "DEMO_MODE=1 draws the twelve demo steps and the demo door, and nothing outside them" do
    before = Rails.application.routes.routes.size
    redraw("1")
    after = Rails.application.routes.routes.size
    KEPT_IN_DEMO.each { |verb, path| assert routed?(verb, path), "#{verb.upcase} #{path} is a demo step and must stay routed" }
    CUT_IN_DEMO.each { |verb, path| refute routed?(verb, path), "#{verb.upcase} #{path} is outside the demo and must not be routed" }
    assert_operator after, :<, before, "the demo draws fewer routes than the full install (#{before} -> #{after})"
  end
end
