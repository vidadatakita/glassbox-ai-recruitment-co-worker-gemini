require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# The report's "Download jawaban" follows feature 07's one rule (TechnicalTests.answer_downloadable_by?)
# and its signed answer_link helper: offered exactly to the roles the route admits, and the offered
# link actually downloads.
class ScreeningReportAnswerLinkTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @open, @closed = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
  end

  def link_for(role, job)
    a = JobApplication.joins(:candidate).find_by!(job:, candidates: { name: "Kandidat Contoh A" })
    sign_in_as staff_user(role)
    get staff_job_screening_report_candidate_path(job, a.id)
    css_select("a").find { |l| l.text.include?("Download answer") }&.[]("href")
  end

  test "offered to reviewer, consultant and HR PIC after close; never to HR PIC before close or the owner; the link downloads" do
    { ["consultant", @open] => true, ["reviewer", @open] => true, ["hr_pic", @closed] => true,
      ["hr_pic", @open] => false, ["owner", @closed] => false }.each do |(role, job), offered|
      href = link_for(role, job)
      assert_equal offered, href.present?, "#{role} on #{job.title}"
      if href
        get href
        assert_response :success, "#{role}: the offered link must download"
        assert_equal "attachment", response.headers["Content-Disposition"].to_s.split(";").first
      end
      sign_out
    end
  end
end
