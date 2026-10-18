require "test_helper"

# The discrimination-check scene on the demo seed (18 Oct 2026): a fourth vacancy, "Warehouse
# Assistant", in DRAFT, whose brief names an age limit. The rule pass flags it "replace" with the
# standard's reason and a neutral wording; nothing is applied, the brief cannot complete until a person
# decides. The three screened demo vacancies keep no flagged line and their AI results stay on the
# current rubric (control).
class DemoSeedDiscriminationSceneTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    @scene = Job.find_by!(title: DemoGlassbox::SCENE_VACANCY[:title])
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "the draft vacancy shows one open Replace line with the reason and a neutral wording, and cannot complete yet" do
    flagged = Briefs::RequirementCheck.open_lines(@scene)
    assert_equal [DemoGlassbox::FLAGGED_REQUIREMENT[:text]], flagged.map { |l| l["text"] }
    line = flagged.first
    assert_equal "replace", line["verdict"]
    assert_predicate line["reason"], :present?
    assert_equal DemoGlassbox::FLAGGED_REQUIREMENT[:replacement], line["replacement"]
    refute @scene.brief_complete?
    assert(Briefs::BriefCheck.new(@scene).problems.any? { |p| p.message.include?("flagged by the discrimination test") })
    assert_equal :never_opened, ApplicationWindow.new(@scene).state
    assert_equal 0, @scene.job_applications.count

    sign_in_as User.find_by!(email_address: "hr@terangnusantara.example")
    get staff_job_brief_path(@scene)
    assert_response :success
    assert_includes response.body, DemoGlassbox::FLAGGED_REQUIREMENT[:text]
    assert_includes response.body, DemoGlassbox::FLAGGED_REQUIREMENT[:replacement]
  end

  test "control: the three screened vacancies have no flagged line and no result under an old rubric; a second run adds nothing" do
    Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).each do |job|
      assert_empty Briefs::RequirementCheck.open_lines(job), job.title
      assert_empty ScreeningBoard.new(job).stale, "#{job.title}: AI results stay on the current rubric"
    end
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    assert_equal 1, Job.where(title: DemoGlassbox::SCENE_VACANCY[:title]).count
  end
end
