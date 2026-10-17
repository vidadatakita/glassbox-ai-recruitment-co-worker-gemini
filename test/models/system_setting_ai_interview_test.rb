require "test_helper"

class SystemSettingAiInterviewTest < ActiveSupport::TestCase
  test "ai_interview is off by default" do
    assert_equal false, SystemSetting.ai_interview?
  end

  test "ai_interview can be switched on and the change is audited" do
    admin = staff_user("admin")
    Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor: admin)
    assert_equal true, SystemSetting.ai_interview?(company: admin.client_company)
    assert SettingChange.exists?(key: "ai_interview", new_value: "true")
  end
end
