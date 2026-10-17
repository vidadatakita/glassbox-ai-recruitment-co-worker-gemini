require "test_helper"

# Vacancy list, 17 Oct 2026 (Vida): a vacancy whose portal is closed and whose places are all filled
# is finished, so its next step says "Done", not "Continue the selection". "Filled" is
# HeadcountProgress's count (applicants who reached Salary agreed).
class VacancyListNextStepTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    @job = Job.find_by!(title: "Accounting Supervisor")
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  def next_step_for(job)
    get staff_jobs_path
    assert_response :success
    row = css_select("tbody tr").find { |tr| tr.text.include?(job.title) }
    assert row, "the vacancy is listed"
    row.at_css("td[data-label='Next step']").text.squish
  end

  def fill_all_places!(job)
    application = job.job_applications.where.not(candidate_id: nil).order(:id).first
    job.update_columns(headcount: 1)
    SalaryAgreement.create!(job_application: application, agreed_amount: job.salary_min || 5_000_000, outside_band: false,
                            decided_by: User.find_by!(email_address: "admin@glassbox.example"), created_at: Time.current)
  end

  test "closed portal and every place filled: the next step is Done" do
    fill_all_places!(@job)
    Portal::WindowChange.close!(job: @job, actor: User.find_by!(email_address: "hr@terangnusantara.example"), reason: "Enough applicants") if ApplicationWindow.new(@job).open?
    assert HeadcountProgress.new(@job).complete?
    assert_equal "Done: all places filled", next_step_for(@job)
  end

  test "control: closed portal with a place still open continues the selection" do
    @job.update_columns(headcount: 50)
    Portal::WindowChange.close!(job: @job, actor: User.find_by!(email_address: "hr@terangnusantara.example"), reason: "Enough applicants") if ApplicationWindow.new(@job).open?
    refute HeadcountProgress.new(@job).complete?
    assert_equal "Continue the selection", next_step_for(@job)
  end
end
