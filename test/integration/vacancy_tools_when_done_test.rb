require "test_helper"

# Vacancy page, 17 Oct 2026 (Vida): once the hiring is complete (portal closed, every place filled),
# Start screening and Open fairness check are greyed out with the reason (no form or link), the screening
# report stays open as the hiring record, and the gate card reads Done.
class VacancyToolsWhenDoneTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    @job = Job.find_by!(title: "Accounting Supervisor")
    @admin = User.find_by!(email_address: "admin@glassbox.example")
    sign_in_as @admin
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  def complete_hiring!
    application = @job.job_applications.where.not(candidate_id: nil).order(:id).first
    @job.update_columns(headcount: 1)
    SalaryAgreement.create!(job_application: application, agreed_amount: @job.salary_min || 5_000_000, outside_band: false,
                            decided_by: @admin, created_at: Time.current)
    Portal::WindowChange.close!(job: @job, actor: User.find_by!(email_address: "hr@terangnusantara.example"), reason: "Places filled") if ApplicationWindow.new(@job).open?
    assert VacancyNextStep.for(@job, ApplicationWindow.new(@job)).done
  end

  def page_targets
    get staff_job_path(@job)
    assert_response :success
    css_select("a, form").map { |e| e["href"] || e["action"] }.compact
  end

  test "hiring complete: start and fairness greyed, report open, gate Done" do
    Screening::Config.stub(:enabled?, true) do
      complete_hiring!
      targets = page_targets
      [staff_job_screening_start_path(@job), staff_job_fairness_check_path(@job)].each { |path| refute_includes targets, path }
      assert_includes targets, staff_job_screening_report_path(@job), "the report stays open as the hiring record"
      assert_select ".link-waiting", 2
      assert_includes response.body, "Hiring is complete: every place is filled"
      assert_select "details#gerbang-seleksi.section-fold--done", 1
    end
  end

  test "control: a running vacancy keeps the three tools" do
    @job.update_columns(headcount: 50)
    Screening::Config.stub(:enabled?, true) do
      targets = page_targets
      assert_includes targets, staff_job_screening_report_path(@job)
      assert_includes targets, staff_job_screening_start_path(@job)
      assert_select ".link-waiting", 0
    end
  end
end
