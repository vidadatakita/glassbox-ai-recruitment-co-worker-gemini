require "test_helper"

# The discrimination-check scene on the demo seed (18 Oct 2026): Admin Staff carries one requirement
# that names age, flagged "replace" by the rule pass with a neutral wording, left open for a person.
# Accounting Supervisor (the film's vacancy 1) is unchanged: no flagged line, brief complete.
class DemoSeedDiscriminationSceneTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "Admin Staff shows one open Replace line with the reason and a neutral wording" do
    job = Job.find_by!(title: "Admin Staff")
    flagged = Briefs::RequirementCheck.open_lines(job)
    assert_equal ["Maximum age 30"], flagged.map { |l| l["text"] }
    line = flagged.first
    assert_equal "replace", line["verdict"]
    assert_predicate line["reason"], :present?
    assert_equal DemoGlassbox::FLAGGED_REQUIREMENT[:replacement], line["replacement"]
    assert job.brief_complete?, "the vacancy keeps its complete brief"
    assert ApplicationWindow.new(job).open?, "and its open portal"

    sign_in_as User.find_by!(email_address: "hr@terangnusantara.example")
    get staff_job_brief_path(job)
    assert_response :success
    assert_includes response.body, "Maximum age 30"
    assert_includes response.body, DemoGlassbox::FLAGGED_REQUIREMENT[:replacement]
  end

  test "control: Accounting Supervisor is untouched and a second seed run adds nothing" do
    job = Job.find_by!(title: "Accounting Supervisor")
    assert_empty Briefs::RequirementCheck.open_lines(job)
    refute job.requirements.exists?(text: "Maximum age 30")
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    assert_equal 1, Job.find_by!(title: "Admin Staff").requirements.where(text: "Maximum age 30").count
  end
end
