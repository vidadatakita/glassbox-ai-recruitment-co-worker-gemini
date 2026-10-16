require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03: Briefs::SyncStages writes the Stage rows the scoring core reads (feature
# 01). Weights and thresholds copied exactly, score sources per §1.1, RC weight 0 outside the 100
# (rule 12), S4 review-below-threshold for G1-3 only (rule 13 / D12), and re-syncs that neither
# duplicate a stage nor touch an opened one.
class JobFormSyncStagesTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  # §1.1 / concept brief §2.4: S1 AI, S2 online test, S3 HR interview, S4 psych test, S5 user interview.
  SPEC_SOURCES = { "S1" => "ai", "S2" => "manual_or_import", "S3" => "scorecard", "S4" => "manual_or_import",
                   "S5" => "scorecard", "RC" => "check" }.freeze

  def rows(job) = job.stages.reload.order(:code).to_h { |s| [s.code, [s.weight.to_d, s.threshold.to_d, s.score_source, s.review_below_threshold]] }

  test "completion writes exactly the package's stages with the typed weights and thresholds" do
    weights = { "S1" => 15, "S2" => 15, "S3" => 20, "S4" => 20, "S5" => 30 }
    job = briefed_job(golongan: 4, package: 4, complete: false)
    plan = step4_params(package: 4, weights:)
    plan[:stage_plan]["S3"][:threshold] = "62,5"
    plan[:stage_plan]["S5"][:threshold] = "100"
    plan[:stage_plan]["S2"][:threshold] = "0"
    save_step!(job, "4", plan)
    assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    got = rows(job)
    assert_equal SPEC_STAGES[4].sort, got.keys.sort
    weights.each { |code, w| assert_equal w, got[code][0].to_i, code }
    assert_equal 100, got.except("RC").values.sum { |r| r[0] }
    assert_equal [62.5, 100, 0, 60, 60].map(&:to_d), %w[S3 S5 S2 S1 S4].map { |c| got[c][1] }
    assert_equal [0, 0], got["RC"][0, 2].map(&:to_i), "RC carries no weight and no threshold"
    got.each { |code, r| assert_equal SPEC_SOURCES[code], r[2], code }
    assert(job.stages.all? { |s| s.status == "draft" && s.opened_at.nil? }, "completion opens nothing")
  end

  test "S4 review below threshold is set for G1-3 only (rule 13), including after a Golongan change" do
    { 1 => true, 2 => true, 3 => true, 4 => false, 5 => false, 6 => false, 8 => false }.each do |g, review|
      job = briefed_job(golongan: g, package: 4)
      assert_equal review, job.stages.find_by!(code: "S4").review_below_threshold, "G#{g}"
      assert_equal [false], job.stages.where.not(code: "S4").pluck(:review_below_threshold).uniq, "G#{g}: only S4"
    end
    job = briefed_job(golongan: 3, package: 4)
    save_step!(job, "1", step1_params(golongan: 4))
    refute job.stages.find_by!(code: "S4").review_below_threshold, "G3 -> G4 kept the staff-level review"
    save_step!(job, "1", step1_params(golongan: 3))
    assert job.stages.find_by!(code: "S4").review_below_threshold, "G4 -> G3 did not restore it"
  end

  test "re-syncing a complete brief after edits never duplicates a stage and follows the new values" do
    job = briefed_job(golongan: 4, package: 4)
    ids = job.stages.order(:code).pluck(:code, :id)
    3.times { save_step!(job, "4", step4_params(package: 4)) }
    assert_equal ids, job.stages.order(:code).pluck(:code, :id), "stages were re-created or duplicated"
    w = Briefs::StagePlan.default_weights(4)
    save_step!(job, "4", step4_params(package: 4, weights: w.merge("S1" => 5, "S5" => 35), threshold: "70"))
    assert_equal [5, 35], [job.stages.find_by!(code: "S1").weight.to_i, job.stages.find_by!(code: "S5").weight.to_i]
    assert_equal [70], job.stages.where.not(code: "RC").pluck(:threshold).map(&:to_i).uniq
    assert_equal ids, job.stages.order(:code).pluck(:code, :id)
    assert_equal 6, Stage.where(job:).count
  end

  test "a package change on a complete brief removes the dropped draft stages and adds the new ones" do
    job = briefed_job(golongan: 6, package: 4)
    save_step!(job, "4", step4_params(package: 3).merge(package_override_reason: "Klien meminta proses lebih singkat"))
    assert_equal SPEC_STAGES[3].sort, job.stages.pluck(:code).sort
    save_step!(job, "4", step4_params(package: 5))
    assert_equal SPEC_STAGES[5].sort, job.stages.pluck(:code).sort
  end

  test "a package change that would drop a stage with candidates in it is refused whole" do
    job = briefed_job(golongan: 4, package: 4)
    s4 = job.stages.find_by!(code: "S4")
    Participation.create!(job_application: JobApplication.create!(job:), stage: s4, attendance: "attended")
    before = [job.reload.package, job.stage_plan, job.stages.order(:code).pluck(:code, :weight)]
    result = run_step(job, "4", step4_params(package: 3).merge(package_override_reason: "Klien meminta"))
    refute result.ok?
    assert(result.errors.any? { |e| e.include?("already holds applicants") }, result.errors.inspect)
    assert_equal before, [job.reload.package, job.stage_plan, job.stages.order(:code).pluck(:code, :weight)]
  end

  test "SyncStages never rewrites an opened stage, even when called directly" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S2")
    job.update_columns(stage_plan: job.stage_plan.merge("S2" => { "weight" => 99, "threshold" => 1 }))
    assert_raises(Briefs::SyncStages::Refused) { Briefs::SyncStages.call(job.reload) }
    assert_equal [20, 60], job.stages.find_by!(code: "S2").then { |s| [s.weight.to_i, s.threshold.to_i] }
  end
end
