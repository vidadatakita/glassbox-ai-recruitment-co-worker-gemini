require "test_helper"

class StaffSettingsAiInterviewTest < ActionDispatch::IntegrationTest
  test "the settings screen shows the AI interview switch and an admin can turn it on" do
    admin = staff_user("admin")
    sign_in_as admin
    get staff_settings_path
    assert_response :success
    assert_select "input[name=key][value=ai_interview]"

    patch staff_settings_path, params: { key: "ai_interview", value: "1" }
    assert_redirected_to staff_settings_path
    assert SystemSetting.ai_interview?(company: admin.client_company)
  end
end
