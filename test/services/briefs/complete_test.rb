require "test_helper"

class Briefs::CompleteTest < ActiveSupport::TestCase
  test "completing writes draft stages for the package with the brief's weights and thresholds" do
    job = briefed_job(golongan: 2, package: 3)
    stages = job.stages.order(:code).to_a
    assert_equal %w[S1 S2 S3 S5], stages.map(&:code)
    assert_equal %w[draft], stages.map(&:status).uniq
    assert_equal 100, stages.sum(&:weight)
    assert_equal %w[ai manual_or_import scorecard scorecard], stages.map(&:score_source)
    assert job.brief_complete?
    assert_equal "complete", job.brief_changes.order(:id).last.step
  end

  test "S4 is review-below-threshold for G3 and not for G4 (rule 13); RC carries weight 0" do
    g3 = briefed_job(golongan: 3, package: 4)
    assert g3.stages.find_by!(code: "S4").review_below_threshold
    assert_equal 0, g3.stages.find_by!(code: "RC").weight
    g4 = briefed_job(golongan: 4, package: 4)
    refute g4.stages.find_by!(code: "S4").review_below_threshold
  end

  test "an incomplete brief is refused with its problems and no stages are written" do
    job = briefed_job(complete: false)
    job.activities.first.update!(share_percent: 10)
    result = Briefs::Complete.call(job:, actor: staff_user("hr_pic"))
    refute result.ok?
    assert(result.problems.any? { |p| p.step == 2 })
    assert_equal 0, job.stages.count
    refute job.reload.brief_complete?
  end

  test "changing the package of a complete brief removes the draft stage it no longer runs" do
    job = briefed_job(golongan: 2, package: 3)
    save_step!(job, "4", step4_params(package: 2, layers: BriefFactory::ALL_LAYERS).tap { |p|
      p[:competencies].each_value { |c| c[:stage_code] = "S5" }
    })
    assert_equal %w[S1 S5], job.stages.order(:code).pluck(:code)
  end
end
