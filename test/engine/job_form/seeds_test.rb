require "test_helper"
require_relative "job_form_engine_support"
require Rails.root.join("db/seeds/demo_jobs")

# Test engine, feature 03: the six D49 demo jobs, checked against the SPEC oracles (not against
# Briefs::BriefCheck alone, which is the code under test), and a second run that changes nothing.
class JobFormSeedsTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  # D49: "Operator G2, Team Leader G3, Supervisor G4, Manager G6, General Manager G7, Direktur G8".
  # The demo titles are English (17 Oct 2026), so the role word is matched as a whole word anywhere
  # in the title ("Production Operator", "HR Manager") and the spec's "Direktur" reads "Director".
  D49 = [["Operator", 2], ["Team Leader", 3], ["Supervisor", 4], ["Manager", 6], ["General Manager", 7], ["Director", 8]].freeze

  def footprint
    [Job.count, Activity.count, Requirement.count, KnockoutQuestion.count, Competency.count, Stage.count,
     JobBriefChange.count, Job.order(:id).pluck(:id, :brief_completed_at, :updated_at)]
  end

  test "each seed job meets the spec on its own, and a second run changes nothing" do
    legacy = Job.create!(title: "Staf Lama", golongan: 2, client_company: company)
    jobs = DemoJobs.run(company:, actor: staff_user("hr_pic"))
    D49.zip(jobs).each do |(prefix, g), job|
      assert_match(/\b#{prefix}\b/, job.title, "#{job.title} vs D49 #{prefix}")
      assert_equal g, job.golongan, job.title
      assert job.brief_complete?, job.title
      shares = job.activities.pluck(:share_percent)
      assert_includes 5..8, shares.size, job.title
      assert_equal 100, shares.sum, job.title
      should = job.requirements.where(tier: "sebaiknya").pluck(:weight)
      assert_equal 100, should.sum, job.title if should.any?
      assert_includes 2..3, job.knockout_questions.count, job.title
      assert(job.knockout_questions.all? { |q| q.requirement&.tier == "wajib" }, "#{job.title}: knockout on a non-wajib line")
      assert_includes SPEC_PACKAGES[g], job.package, job.title
      assert_equal SPEC_STAGES[job.package].sort, job.stages.pluck(:code).sort, job.title
      assert_equal 100, job.stages.where.not(code: "RC").sum(:weight).to_i, job.title
      assert_empty spec_required_layers(g) - job.competencies.pluck(:layer), "#{job.title}: §2.3 coverage"
      assert(job.competencies.all? { |c| SPEC_STAGES[job.package].include?(c.stage_code) }, "#{job.title}: competency owned by a stage the package does not run")
      assert(job.salary_min <= job.salary_max && job.salary_min.positive?, job.title)
      assert job.placements.any?, job.title
      assert_equal (g <= 3), job.stages.find_by(code: "S4")&.review_below_threshold || false, "#{job.title}: rule 13" if job.package >= 4
    end
    before = footprint
    again = DemoJobs.run(company:, actor: staff_user("hr_pic"))
    assert_equal jobs.map(&:id), again.map(&:id)
    assert_equal before, footprint, "a second seed run changed rows"
    assert_equal ["Staf Lama", "draft"], [legacy.reload.title, legacy.brief_status], "the seed touched a job it does not own"
  end
end
