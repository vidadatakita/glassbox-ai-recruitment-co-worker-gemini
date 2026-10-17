require "test_helper"

class SystemSettingAiInterviewTest < ActiveSupport::TestCase
  test "ai_interview is off by default" do
    assert_equal false, SystemSetting.ai_interview?
  end

  test "ai_interview can be switched on and the change is audited" do
    admin = staff_user("admin")
    switch_ai_interview_on(actor: admin)
    assert_equal true, SystemSetting.ai_interview?(company: admin.client_company)
    assert SettingChange.exists?(key: "ai_interview", new_value: "true")
  end

  # The guard (18 Oct 2026, UU PDP Pasal 21): no switching on, and no interview, without a consent
  # text that names the AI interview.
  test "the switch refuses to turn on while the consent text does not name the AI interview" do
    ConsentTemplate.create!(ConsentTemplate::SECTIONS.keys.to_h { |f| [f, "Plain text for #{f}."] }.merge(version: "plain", effective_from: 1.hour.ago, created_at: Time.current))
    error = assert_raises(Portal::UpdateSetting::Invalid) { Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor: staff_user("admin")) }
    assert_match "names the AI interview", error.message
    assert_equal false, SystemSetting.ai_interview?(company: staff_user("admin").client_company)
    Portal::UpdateSetting.call(key: "ai_interview", value: "0", actor: staff_user("admin")) # switching off is always allowed
  end

  test "a switch already on creates no interview while the consent text does not name it" do
    plain = ConsentTemplate.create!(ConsentTemplate::SECTIONS.keys.to_h { |f| [f, "Plain text for #{f}."] }.merge(version: "plain", effective_from: 1.hour.ago, created_at: Time.current))
    SystemSetting.create!(key: "ai_interview", value: "true", client_company_id: nil)
    job = Job.new(client_company: nil)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:review_before_ai?, false) do
        refute Interviews.enabled_for?(job), "no consent naming it: no interview"
        ConsentTemplate.create!(plain.with_ai_interview_addendum.merge(version: "named", effective_from: 1.minute.ago, created_at: Time.current))
        assert Interviews.enabled_for?(job), "control: once the text names it, the interview runs"
      end
    end
  end
end
