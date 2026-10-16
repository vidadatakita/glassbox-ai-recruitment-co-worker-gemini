require "test_helper"
require Rails.root.join("db/seeds/demo_jobs")

# Feature 07 seeds: each D49 demo job of package 3+ gets one approved, invented test case; a second
# run writes nothing. The workbook is re-opened and checked, not trusted (conventions §8 rule 5).
class DemoTestCasesSeedTest < ActiveSupport::TestCase
  test "every package-3+ demo job has one approved test with a safe xlsx and a 100% rubric; a second run writes nothing" do
    jobs = DemoJobs.run(company:, actor: staff_user("hr_pic"))
    assert_equal 6, jobs.size
    jobs.each do |job|
      tc = TechnicalTestCase.current_for(job)
      assert tc, job.title
      assert_equal [1, 100, "xlsx"], [tc.version, tc.criteria.sum(&:weight), tc.case_file_kind], job.title
      assert(tc.criteria.all? { |c| job.activities.map(&:id).include?(c.activity_id) }, job.title)
      bytes = tc.case_file.download
      assert TestCases::FileInspection.call(io: StringIO.new(bytes), filename: "x.xlsx").ok?, job.title
      require "zip"
      xml = nil
      Zip::File.open_buffer(bytes) { |zip| xml = zip.read("xl/workbook.xml") }
      sheets = xml.scan(/<sheet [^>]*name="([^"]+)"/).flatten
      assert_equal %w[Petunjuk Data Jawaban], sheets, job.title
    end
    before = [TechnicalTestCase.count, TestCaseCriterion.count, JobBriefChange.count, ActiveStorage::Attachment.count]
    DemoJobs.run(company:, actor: staff_user("hr_pic"))
    assert_equal before, [TechnicalTestCase.count, TestCaseCriterion.count, JobBriefChange.count, ActiveStorage::Attachment.count]
  end
end
