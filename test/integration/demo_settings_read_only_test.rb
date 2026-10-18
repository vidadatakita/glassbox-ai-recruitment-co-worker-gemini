require "test_helper"

# Demo mode (18 Oct 2026, the team lead): the work queue is on the demo, and the system settings are
# shown READ-ONLY: no form, no Save button, and the saving routes are not drawn, so a crafted request
# changes nothing. Control: outside demo mode the settings page keeps its forms.
class DemoSettingsReadOnlyTest < ActionDispatch::IntegrationTest
  include PortalFactory

  teardown { with_env("DEMO_MODE" => nil) { Rails.application.reload_routes! } }

  def in_demo_mode(&)
    with_env("DEMO_MODE" => "1") do
      Rails.application.reload_routes!
      yield
    end
  end

  test "demo mode: work queue opens; settings are shown without any form or Save, and cannot be saved" do
    set_retention(30)
    in_demo_mode do
      sign_in_as staff_user("superadmin")
      get staff_work_queue_path
      assert_response :success
      get staff_settings_path
      assert_response :success
      assert_includes response.body, "Read-only on the public demo"
      assert_select "form", 1, "only the header's sign-out form remains" if css_select("form").any?
      assert_select "main form, .content form", 0
      assert_select "fieldset.settings-readonly[disabled]", minimum: 5
      refute_match(/>\\s*Save( as new version)?\\s*</, response.body)
      assert_select "a[href='#{staff_settings_path}']", minimum: 1 # listed in the menu
      patch "/staff/settings", params: { key: "retention_days", value: "1" }
      assert_response :not_found
      post "/staff/settings/consent", params: { consent: { purpose: "x" } }
      assert_response :not_found
      assert_equal 30, SystemSetting.retention_days, "nothing was saved"
    end
  end

  test "control: outside demo mode the settings keep their forms and Save buttons" do
    with_env("DEMO_MODE" => nil) do
      Rails.application.reload_routes!
      sign_in_as staff_user("superadmin")
      get staff_settings_path
      assert_response :success
      assert_select "fieldset.settings-readonly", 0
      assert_select "form[action='#{staff_settings_path}']", minimum: 5
      refute_includes response.body, "Read-only on the public demo"
    end
  end
end
