require "test_helper"
require_relative "engine07_support"

# Test engine, feature 07 slice 1: Lamar enters S1 and S2 at once on GATED jobs only, through the
# real chain (brief wizard -> Briefs::Complete -> SyncStages sets the gate -> portal -> submit).
class Engine07GateLamarTest < ActiveSupport::TestCase
  include Engine07Support

  def live_job(package:, golongan:)
    job = briefed_job(golongan:, package:) # factory adds the approved test where the package runs S2
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id)
    open_portal(job)
    job.reload
  end

  def codes_entered(application) = application.participations.includes(:stage).map { |p| p.stage.code }.sort

  test "packages 3, 4, 5: Lamar enters S1 and S2; package 2: S1 only; gate column only on S1/S2 of 3+" do
    { 2 => 2, 3 => 3, 4 => 4, 5 => 6 }.each do |package, golongan|
      job = live_job(package:, golongan:)
      application, = submit!(job)
      expected = package == 2 ? %w[S1] : %w[S1 S2]
      assert_equal expected, codes_entered(application), "package #{package}"
      gated = job.stages.where.not(gate: nil).order(:code).pluck(:code)
      assert_equal(package == 2 ? [] : %w[S1 S2], gated, "package #{package}")
    end
  end

  test "a knockout 'tidak' on a DRAFT gate is decided by rule on BOTH stages when the gate opens" do
    job = live_job(package: 3, golongan: 3)
    answers = answers_for(job).merge(job.knockout_questions.first.id.to_s => "tidak")
    application, = submit!(job, knockout: answers)
    assert(application.participations.all? { |p| p.current_decision.nil? }, "decided on a draft stage")
    Stages::Open.call(stage: job.stages.find_by!(code: "S2"))
    reasons = application.participations.reload.map { |p| p.current_decision&.reason_code }
    assert_equal %w[knockout knockout], reasons
    assert_equal "draft", job.stages.find_by!(code: "S3").status, "control: S3 not opened by the gate"
  end

  test "a package 3 brief whose S2 was later dropped to package 2 loses the gate (draft) and Lamar enters S1 only" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    save_step!(job, "4", step4_params(package: 2, golongan: 2))
    assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    assert_equal [nil], job.stages.where(code: "S1").pluck(:gate)
    assert_empty job.stages.where(code: "S2")
  end
end
