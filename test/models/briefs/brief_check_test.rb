require "test_helper"

# Briefs::BriefCheck is the completion gate. Each test starts from a brief that passes (the
# control) and breaks exactly one rule, so a red names the rule that stopped working.
class Briefs::BriefCheckTest < ActiveSupport::TestCase
  def messages(job) = Briefs::BriefCheck.new(job.reload).problems.map(&:message)

  # D60 slice 2: package 3 runs S2, so the factory's passing brief includes an approved test version.
  setup { @job = briefed_job(golongan: 2, package: 3, complete: false) }

  test "control: the factory brief passes" do
    assert_empty messages(@job)
  end

  test "D60: a package that runs S2 needs an approved technical test (step 5)" do
    job = briefed_job(golongan: 2, package: 3, complete: false, test_case: false)
    # 17 Oct 2026 (slice B): the competency bank is the first way to build the test; the upload the other.
    assert_equal [[5, "The technical test has not been created. Build the competency bank in step 5 (or upload a case document), then have it approved."]],
                 Briefs::BriefCheck.new(job).problems.map { |p| [p.step, p.message] }
  end

  test "activity shares must sum to exactly 100" do
    @job.activities.first.update!(share_percent: 29)
    assert_includes messages(@job), "The activity time shares add up to 99%; they must add up to exactly 100%."
  end

  test "5 to 8 activities" do
    save_step!(@job, "2", step2_params(shares: [40, 30, 30]))
    assert_includes messages(@job), "There are 3 activities; enter 5 to 8 activities."
    save_step!(@job, "2", step2_params(shares: [20, 20, 20, 10, 10, 10, 5, 5]))
    assert_empty messages(@job), "8 activities is allowed"
  end

  test "sebaiknya weights must sum to exactly 100" do
    @job.requirements.find_by!(tier: "sebaiknya", position: 4).update!(weight: 61)
    assert_includes messages(@job), "The should-have weights add up to 101%; they must add up to exactly 100%."
  end

  test "2 to 3 knockout questions" do
    save_step!(@job, "3", step3_params(knockouts: ["Bersedia bekerja shift?"]))
    assert_includes messages(@job), "There are 1 knockout questions; enter 2 to 3 questions on must-have requirements."
  end

  test "stage weights must sum to exactly 100 and RC is outside the sum" do
    plan = @job.stage_plan.deep_dup
    plan["S5"]["weight"] = 36
    @job.update!(stage_plan: plan)
    assert(messages(@job).any? { |m| m.start_with?("The stage weights add up to 99%") })
  end

  test "a threshold outside 0-100 or missing is refused" do
    plan = @job.stage_plan.deep_dup
    plan["S1"]["threshold"] = nil
    @job.update!(stage_plan: plan)
    assert_includes messages(@job), "The pass score of CV screening is required, a number from 0 to 100."
  end

  test "coverage: a G2 map without L4 is refused and names L4" do
    save_step!(@job, "4", step4_params(package: 3, layers: %w[L1 I]))
    assert(messages(@job).any? { |m| m.include?("L4 Work skill") })
  end

  test "a competency owned by a stage the package does not run is refused" do
    @job.competencies.first.update!(stage_code: "S4")
    assert(messages(@job).any? { |m| m.include?("which this package does not run") })
  end

  test "an interview-stage competency needs questions; anchors 1/3/5 are required" do
    @job.competencies.first.update!(questions: nil)
    assert(messages(@job).any? { |m| m.include?("write its questions") })
    @job.competencies.second.update!(anchor_3: nil)
    assert(messages(@job).any? { |m| m.include?("scores 1, 3 and 5") })
  end

  test "a package outside the recommendation needs a reason" do
    @job.update!(package: 5)
    assert(messages(@job).any? { |m| m.include?("Write the reason") })
    @job.update!(package_override_reason: "Klien meminta referensi")
    refute(messages(@job).any? { |m| m.include?("Write the reason") }, "control: reason given")
  end

  test "salary band and at least one placement" do
    @job.update!(salary_max: nil, placements: [])
    assert_includes messages(@job), "The salary band (minimum and maximum) is required."
    assert_includes messages(@job), "Enter at least one placement."
  end
end
