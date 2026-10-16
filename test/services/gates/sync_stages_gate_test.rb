require "test_helper"

# D60 default (accepted 16:36): the test runs in the apply flow only when the package runs S2
# (packages 3+); package 2 keeps screening = S1 alone, without a gate.
class Gates::SyncStagesGateTest < ActiveSupport::TestCase
  include GateFactory

  test "packages 3 and 4 link S1 and S2 as the gate; no other stage carries it" do
    [3, 4].each do |package|
      job = briefed_job(golongan: package == 3 ? 3 : 4, package:)
      gated = job.stages.where.not(gate: nil).order(:code).pluck(:code, :gate)
      assert_equal [%w[S1 screening], %w[S2 screening]], gated, "package #{package}"
    end
  end

  test "package 2 runs S1 alone, without a gate" do
    job = briefed_job(golongan: 2, package: 2)
    assert_equal %w[S1 S5], job.stages.order(:code).pluck(:code)
    assert_empty job.stages.where.not(gate: nil)
  end

  test "Lamar puts an applicant into S1 and S2 at once on a gated job" do
    job, s1, s2 = gated_job
    open_lamar(job)
    Gates::Open.call(stage: s1)
    result = Portal::SubmitApplication.call(job:, params: lamar_params(job))
    assert_empty result.errors
    assert_equal [s1.id, s2.id], result.application.participations.order(:stage_id).pluck(:stage_id)
  end

  test "control: on a job without a gate Lamar puts the applicant into the first stage only" do
    job = portal_job
    open_portal(job)
    result = Portal::SubmitApplication.call(job:, params: lamar_params(job))
    assert_equal [job.stages.find_by!(code: "S1").id], result.application.participations.pluck(:stage_id)
  end

  test "a knockout tidak on an open gate is decided by rule on both stages" do
    job, s1, = gated_job
    open_lamar(job)
    Gates::Open.call(stage: s1)
    answers = answers_for(job).merge(job.knockout_questions.first.id.to_s => "tidak")
    result = Portal::SubmitApplication.call(job:, params: lamar_params(job, knockout: answers))
    reasons = result.application.participations.map { |p| p.current_decision&.reason_code }
    assert_equal %w[knockout knockout], reasons
  end

  private

  def open_lamar(job)
    job.update!(client_company: company, ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id,
                brief_status: "complete")
    job.knockout_questions.create!(position: 1, text: "Bersedia bekerja shift?")
    open_portal(job)
  end

  def lamar_params(job, overrides = {})
    application_params(job, overrides).merge(consent_token: shown_consent_token)
  end
end
