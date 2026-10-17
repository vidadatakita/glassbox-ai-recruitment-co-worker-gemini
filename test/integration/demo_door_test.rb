require "test_helper"

# A5 (Cup rule "works without login"): the demo door at /demo. Exists only in DEMO_MODE=1 (routes
# drawn from the flag, so the suite redraws them per test and restores its own afterwards), asks for
# no credential, signs the visitor into the seeded account of the chosen role, and logs that sign-in
# as auth_method "demo". Control: without the flag the door is not routed at all.
class DemoDoorTest < ActionDispatch::IntegrationTest
  include PortalFactory

  setup do
    @hr = staff_user("hr_pic")
    @reviewer = staff_user("reviewer")
    @owner = staff_user("owner")
  end

  teardown { with_env("DEMO_MODE" => nil) { Rails.application.reload_routes! } }

  def in_demo_mode(&)
    with_env("DEMO_MODE" => "1") do
      Rails.application.reload_routes!
      yield
    end
  end

  test "the door shows three roles, asks for no password, and names the data as invented" do
    in_demo_mode do
      get "/demo"
      assert_response :success
      assert_select "form[action='/demo'] button", count: 3
      assert_select "input[type=password]", count: 0
      assert_select "form form", { count: 0 }, "a form inside a form (house hard rule)"
      assert_select "[disabled]", count: 0
      # The auth layout's card logo and the page's own logo once both rendered (17 Oct 2026).
      assert_select "img[src*='glassbox-logo']", { count: 1 }, "the logo shows once"
      assert_includes response.body, "invented"
      ["HR Admin", "HR Manager", "Superadmin"].each { |title| assert_includes response.body, "Enter as #{title}" }
    end
  end

  test "entering a door signs the visitor into that role's seeded account and logs it as a demo sign-in" do
    in_demo_mode do
      assert_difference -> { SignInEvent.where(auth_method: "demo", outcome: "success").count }, 1 do
        post "/demo", params: { role: "hr_manager" }
      end
      assert_redirected_to "/staff"
      follow_redirect!
      assert_response :success
      assert_equal @reviewer.id, SignInEvent.order(:id).last.user_id
      assert_includes response.body, @reviewer.name # the first hr_manager account by id
      post "/demo", params: { role: "superadmin" }
      # The fixtures hold superadmin accounts too, so the door's account is any superadmin.
      assert_equal "superadmin", SignInEvent.order(:id).last.user.role
    end
  end

  test "an unknown door (and the old five-role door names) is refused, and the HR Admin door lands on the staff screens" do
    in_demo_mode do
      %w[root hr reviewer owner].each do |door|
        post "/demo", params: { role: door }
        assert_redirected_to "/demo", door
      end
      post "/demo", params: { role: "hr_admin" }
      assert_redirected_to "/staff"
      assert_equal @hr.id, Session.order(:id).last.user_id
    end
  end

  test "control: without DEMO_MODE the door does not exist" do
    with_env("DEMO_MODE" => nil) do
      Rails.application.reload_routes!
      get "/demo"
      assert_response :not_found
    end
  end

  test "the reset refuses to run outside demo mode, and the scheduled job skips when paused" do
    with_env("DEMO_MODE" => nil) do
      result = Demo::Reset.call
      refute result.success?
      assert_match(/DEMO_MODE/, result.error)
    end
    with_env("DEMO_MODE" => "1", "DEMO_RESET" => "off") do
      called = false
      Demo::Reset.stub(:call, ->(**) { called = true }) { DemoResetJob.perform_now }
      refute called, "a paused schedule must not reset the workspace"
    end
  end
end
