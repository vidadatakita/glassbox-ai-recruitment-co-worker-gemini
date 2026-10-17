require "test_helper"
require Rails.root.join("db/seeds/demo_jobs")

# The six demo jobs of db/seeds/demo_jobs.rb (D49) pass the same brief rules as a real brief, and a
# second run changes nothing (idempotent seeds).
class DemoJobsSeedTest < ActiveSupport::TestCase
  test "the six demo jobs complete through the brief services, on the house Golongan template" do
    jobs = DemoJobs.run(company:, actor: staff_user("hr_pic"))
    assert_equal [["Production Operator", 2], ["Warehouse Team Leader", 3], ["Production Supervisor", 4], ["HR Manager", 6],
                  ["General Manager, Operations", 7], ["Operations Director", 8]], jobs.map { |j| [j.title, j.golongan] }
    jobs.each do |job|
      assert job.brief_complete?, job.title
      assert_empty Briefs::BriefCheck.new(job).problems, job.title
      assert_equal Briefs::StagePlan.codes(job.package).sort, job.stages.pluck(:code).sort, job.title
      assert Briefs::PackageAdvisor.recommended?(job.golongan, job.package), "#{job.title}: demo jobs use a recommended package"
    end
    changes = JobBriefChange.count
    again = DemoJobs.run(company:, actor: staff_user("hr_pic"))
    assert_equal jobs.map(&:id), again.map(&:id), "a second run creates no new job"
    assert_equal changes, JobBriefChange.count, "a second run records no change"
  end
end
