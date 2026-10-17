require "test_helper"

# Brief page, 17 Oct 2026 (Vida: "if the brief is complete, what should the user do?"). A complete brief
# shows one next step from VacancyNextStep: write the job ad, then open the portal. A draft brief shows
# its open problems instead (control).
class BriefNextStepTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    @job = Job.find_by!(title: "Accounting Supervisor")
    sign_in_as User.find_by!(email_address: "hr@terangnusantara.example")
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "complete brief without a job ad: the next step is writing it, linked" do
    @job.update_columns(ad_text: nil)
    get staff_job_brief_path(@job)
    assert_response :success
    assert_select "#next-step .test-guide__title", "Write the job ad"
    assert_select "#next-step a[href='#{staff_job_ad_path(@job)}']", 1
  end

  test "complete brief with an ad and a portal never opened: the next step is opening the portal" do
    @job.update_columns(ad_text: "We are hiring.")
    @job.portal_window_events.delete_all if @job.respond_to?(:portal_window_events)
    get staff_job_brief_path(@job)
    title = css_select("#next-step .test-guide__title").text
    assert_equal VacancyNextStep.for(@job, ApplicationWindow.new(@job)).label, title, "the brief page and the list say the same"
  end

  test "control: a draft brief shows no next-step card" do
    @job.update_columns(brief_status: "draft") if @job.has_attribute?(:brief_status)
    refute @job.reload.brief_complete?, "the control needs a draft brief"
    get staff_job_brief_path(@job)
    assert_select "#next-step", 0
  end
end
