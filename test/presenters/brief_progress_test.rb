require "test_helper"

# The brief page's stepper (17 Oct 2026): a step is done only when the brief check has no open problem
# in it; a brief written outside the wizard shows "Recorded", never an invented name.
class BriefProgressTest < ActiveSupport::TestCase
  test "a draft brief: the first step with an open problem is current, later steps wait" do
    job = briefed_job(complete: false)
    job.activities.klass.where(job_id: job.id).delete_all
    progress = BriefProgress.new(job)
    assert_equal :step2, progress.current_key
    refute progress.complete?
    refute progress.steps.find { |s| s.key == :complete }.done?
  end

  test "a complete brief: every step done, the actor is a user or Recorded" do
    job = briefed_job(complete: true)
    progress = BriefProgress.new(job)
    assert progress.complete?, progress.steps.reject(&:done?).map(&:key).inspect
    assert(progress.steps.all? { |s| s.actor.is_a?(User) || s.actor == "Recorded" })
  end
end
