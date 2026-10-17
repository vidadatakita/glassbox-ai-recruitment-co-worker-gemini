require "test_helper"

# The vacancy stepper and approval chain (17 Oct 2026) on the seeded demo: every step reads a record the
# step writes, the order is the workflow order, and the chain names users only.
class HiringProgressTest < ActiveSupport::TestCase
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "the seeded Accounting vacancy: brief to step decision done, in order, salary and close still open" do
    progress = HiringProgress.new(Job.find_by!(title: "Accounting Supervisor"))
    keys = progress.steps.map(&:key)
    assert_equal %i[brief ad test open release decision interview salary close], keys
    done = progress.steps.select(&:done?).map(&:key)
    assert_equal keys.first(done.size), done, "done steps are a prefix of the workflow: no gap before a later done step"
    assert_includes done, :decision
    refute progress.complete?
    assert(progress.chain.all? { |link| link.person.nil? || link.person.is_a?(User) }, "the chain names users only")
  end

  test "a package without a technical test has no test step" do
    job = Job.find_by!(title: "Accounting Supervisor")
    job.update_columns(package: 2)
    refute_includes HiringProgress.new(job).steps.map(&:key), :test
  end
end
