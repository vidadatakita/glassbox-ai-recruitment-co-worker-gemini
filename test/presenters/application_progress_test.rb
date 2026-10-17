require "test_helper"

# The applicant page's stepper (17 Oct 2026): every step reads its own record, the vacancy's later stages
# each get a step, and nothing is done before it happened.
class ApplicationProgressTest < ActiveSupport::TestCase
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "a seeded applicant: applied is done, the vacancy's stages are steps, salary and offer wait" do
    job = Job.find_by!(title: "Accounting Supervisor")
    application = job.job_applications.where.not(candidate_id: nil).order(:id).first
    progress = ApplicationProgress.new(application)
    keys = progress.steps.map(&:key)
    assert_equal :applied, keys.first
    assert_equal %i[salary offer], keys.last(2)
    assert_equal job.stages.map(&:code).sort_by { |c| Stage::CODES.index(c) } - ["S1"], keys.grep(/\Astage_/).map { |k| k.to_s.delete_prefix("stage_") }
    assert progress.steps.first.done?
    refute progress.steps.find { |s| s.key == :offer }.done?
    assert(progress.steps.all? { |s| s.actor.nil? || s.actor.is_a?(User) || s.actor.is_a?(String) })
  end
end
