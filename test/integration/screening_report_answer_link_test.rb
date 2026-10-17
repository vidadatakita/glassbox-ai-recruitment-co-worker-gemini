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
    a = JobApplication.joins(:candidate).find_by!(job:, candidates: { name: "Sample Candidate A" })
    sign_in_as staff_user(role)
    get staff_job_screening_report_candidate_path(job, a.id)
    css_select("a").find { |l| l.text.include?("Download answer") }&.[]("href")
  end

  def assert_offered(matrix)
    matrix.each do |(role, job), offered|
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

  # Three roles (17 Oct 2026): the hr_manager (reviewer, owner) scores the test and is offered the
  # answer always; the hr_admin (consultant, HR PIC) once the screening is confirmed (closed).
  test "offered to the hr_manager always and to the hr_admin after close; the link downloads" do
    assert_offered({ ["reviewer", @open] => true, ["owner", @open] => true, ["owner", @closed] => true,
                     ["hr_pic", @closed] => true, ["consultant", @closed] => true })
  end

  # The answer file may carry the candidate's identity in its metadata, and under the three-role
  # model no role sees identity before the gate except the superadmin, who passes every role check.
  # So: never to an hr_admin before close (the old consultant exception went with the old role), and
  # always to the superadmin. Kept failing on purpose if TechnicalTests.answer_downloadable_by? says
  # otherwise (reported as a suspected app defect, 17 Oct 2026).
  test "never offered to an hr_admin before close" do
    assert_offered({ ["hr_pic", @open] => false, ["consultant", @open] => false })
  end

  test "always offered to the superadmin" do
    assert_offered({ ["admin", @open] => true, ["admin", @closed] => true })
  end
end
