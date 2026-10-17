require "test_helper"

# The public demo seed (DEMO_MODE=1) switches the AI interview on for the demo company, under the
# demo-2 consent text that names it (18 Oct 2026). Single-tenant installs (the demo) keep settings
# install-wide (Glassbox::Settings.settings_company_id), so the switch is the installation's.
class DemoSeedAiInterviewTest < ActiveSupport::TestCase
  setup { @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] } }
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "demo seed: consent names the interview and the switch is on for the demo company" do
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    company = User.find_by!(email_address: "hr@terangnusantara.example").client_company
    assert ConsentTemplate.in_force(company:).names_ai_interview?, "demo-2 is the text in force"
    assert SystemSetting.ai_interview?(company:)
    job = Job.find_by!(title: "Accounting Supervisor")
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:review_before_ai?, false) { assert Interviews.enabled_for?(job) }
    end
  end
end
