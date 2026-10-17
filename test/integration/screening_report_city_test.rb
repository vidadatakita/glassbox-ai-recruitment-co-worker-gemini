require "test_helper"
require "zip"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# D54: the city in the report follows the CONTACT rule, on the list, the detail page and the xlsx.
# Three roles (17 Oct 2026): the superadmin always; the HR Admin after the gate closes; never the
# HR Manager.
class ScreeningReportCityTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @open, @closed = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
    @a_open = JobApplication.joins(:candidate).find_by!(job: @open, candidates: { name: "Sample Candidate A" })
  end

  # Read inside the block: open_buffer returns the buffer, not the block's value.
  def shared_strings(body)
    text = nil
    Zip::File.open_buffer(StringIO.new(body)) { |zip| text = zip.read("xl/sharedStrings.xml") }
    text
  end

  def seen?(role, job, path_for)
    sign_in_as staff_user(role)
    get path_for.call(job)
    response.body.include?("Bekasi</") || response.body.include?("<br>Bekasi") || response.body.include?(">Bekasi<")
  ensure
    sign_out
  end

  test "the superadmin sees the city; the HR Admin only after the gate closes; the HR Manager never" do
    detail = ->(job) { staff_job_screening_report_candidate_path(job, JobApplication.joins(:candidate).find_by!(job:, candidates: { name: "Sample Candidate A" }).id) }
    assert seen?("admin", @open, detail), "the superadmin sees City of residence"
    sign_in_as staff_user("admin")
    get detail.call(@open)
    assert_select ".report-facts > div:not([hidden])", text: /City of residence\s*Bekasi/ # displayed, not only present
    sign_out
    refute seen?("hr_pic", @open, detail), "HR PIC before the gate closes"
    refute seen?("consultant", @open, detail), "the other HR Admin before the gate closes"
    assert seen?("hr_pic", @closed, detail), "control: HR PIC after close"
    assert seen?("consultant", @closed, detail), "control: the other HR Admin after close"
    refute seen?("owner", @closed, detail)
    refute seen?("reviewer", @open, detail)
  end

  test "the blind xlsx has no City of residence column; the superadmin's has it" do
    sign_in_as staff_user("hr_pic")
    get staff_job_screening_report_export_path(@open)
    refute_includes shared_strings(response.body), "City of residence"
    sign_out
    sign_in_as staff_user("admin")
    get staff_job_screening_report_export_path(@open)
    strings = shared_strings(response.body)
    assert_includes strings, "City of residence"
    assert_includes strings, "Bekasi"
  end
end
