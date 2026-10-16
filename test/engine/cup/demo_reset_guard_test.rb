require "test_helper"

# A5 (no-login demo, nightly reset). Risk hunted: the reset running on a database that is not the
# demo (it drops the schema), and the demo door existing on a client install. Stated selection: the
# reset's demo-mode path is NOT exercised here (it would drop this test database); only the refusal
# and the route absence are, which is the half that protects a real install.
class CupDemoResetGuardTest < ActiveSupport::TestCase
  include PortalFactory

  test "outside DEMO_MODE the reset refuses, names the reason, and the data is untouched" do
    job = portal_job
    refute Glassbox::Settings.demo_mode?, "the test environment must not run in demo mode"
    result = Demo::Reset.call
    refute result.success?
    assert_match(/DEMO_MODE is not 1/, result.error)
    assert Job.exists?(job.id), "a refused reset must not have dropped anything"
  end

  test "outside DEMO_MODE the demo door route is not drawn" do
    refute Rails.application.routes.url_helpers.respond_to?(:demo_path), "the /demo route exists although DEMO_MODE is off"
  end
end
