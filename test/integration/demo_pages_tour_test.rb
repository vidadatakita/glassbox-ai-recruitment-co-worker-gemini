require "test_helper"

# Every staff page of the seeded Cup demo vacancies renders for every role (17 Oct 2026). The seed
# set brief_status "complete" without brief_completed_at, and the brief page raised NoMethodError on
# all three public-demo vacancies; no test opened the seeded pages, only factory-built ones. This runs
# db/seeds.rb as Demo::Reset does and opens each page as the three demo accounts, plus every
# applicant page of the first vacancy. A redirect (role refused) is allowed; an error page is not.
class DemoPagesTourTest < ActionDispatch::IntegrationTest
  ACCOUNTS = %w[hr@terangnusantara.example manager@terangnusantara.example admin@glassbox.example].freeze

  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  # A package without a technical test (S2) has no test pages: they answer 404 by design
  # (TestCasesController), so they are visited only where they exist, and no page may link to them.
  def s2_pages(job)
    h = Rails.application.routes.url_helpers
    [h.staff_job_test_case_step_path(job), h.staff_job_test_scorings_path(job)]
  end

  def pages(job)
    h = Rails.application.routes.url_helpers
    [h.staff_jobs_path, h.staff_job_path(job), h.staff_job_brief_path(job), h.staff_job_ad_path(job),
     h.staff_job_screening_review_path(job), h.staff_job_screening_calibration_path(job), h.staff_job_ai_releases_path(job),
     h.staff_job_fairness_check_path(job), h.staff_job_screening_report_path(job)] +
      (TestCases::Requirement.applies?(job) ? s2_pages(job) : [])
  end

  test "every page of every seeded demo vacancy renders for every demo account" do
    jobs = Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).order(:id).to_a
    assert_equal 3, jobs.size
    assert(jobs.all? { |j| j.brief_completed_at.present? }, "a complete brief carries its completion time")
    applications = jobs.first.job_applications.where.not(candidate_id: nil).order(:id).to_a
    assert_operator applications.size, :>=, 5

    ACCOUNTS.each do |email|
      user = User.find_by!(email_address: email)
      sign_in_as user
      paths = jobs.flat_map { |job| pages(job) }.uniq + applications.map { |a| staff_application_path(a) }
      dead = jobs.reject { |job| TestCases::Requirement.applies?(job) }.flat_map { |job| s2_pages(job) }
      paths.each do |path|
        get path
        assert_includes [200, 302], response.status, "#{email} (#{user.role}) #{path}: HTTP #{response.status}"
        dead.each { |d| refute_includes response.body, "href=\"#{d}\"", "#{path} links to #{d}, which does not exist" }
      end
      sign_out
    end
  end

  # A complete brief must pass its own check on every save (Briefs::SaveStep), so a seeded complete brief
  # that fails Briefs::BriefCheck can never be saved again: "Save & next does not work" on every Cup
  # vacancy, 17 Oct 2026 (found by the test engine from a live report).
  test "every seeded complete brief passes the brief check, so its steps can be saved" do
    jobs = Job.where(brief_status: "complete").where.not(brief_completed_at: nil).order(:id).to_a
    assert_operator jobs.size, :>=, 3
    jobs.each do |job|
      problems = Briefs::BriefCheck.new(job).problems
      assert_empty problems.map { |pr| "step #{pr.step}: #{pr.message}" }, "#{job.title} is seeded complete but fails its brief check"
    end
  end

  # Tie-out (a displayed total equals its parts): the vacancy list's total, each row's count, and the
  # shares, which add up to 100% within rounding.
  test "the vacancy list: the total equals the rows, and the shares add up to 100" do
    sign_in_as User.find_by!(email_address: ACCOUNTS.first)
    get staff_jobs_path
    doc = Nokogiri::HTML(response.body)
    total = doc.at_css("p.text-muted.small strong").text.to_i
    counts = doc.css("td.job-share > strong").map { |n| n.text.to_i }
    shares = doc.css(".job-share__pct").map { |n| n.text.to_i }
    assert_equal 3, counts.size
    assert_equal total, counts.sum
    assert_equal JobApplication.where(job_id: Job.where(title: DemoGlassbox::JOBS.values.pluck(:title))).where.not(candidate_id: nil).count, total
    assert_in_delta 100, shares.sum, 2
  end

  # The public apply links of the three demo vacancies open (Admin Staff: the three-step form with the
  # question bank; the others: the two-step form), signed out, as an applicant would.
  test "every demo apply link opens for a signed-out applicant" do
    Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).find_each do |job|
      get lamar_path(job.public_code)
      follow_redirect! while response.redirect?
      assert_response :success, "#{job.title}: /apply/#{job.public_code}"
      assert_select "form", { minimum: 1 }, "#{job.title}: the apply page offers a form"
    end
  end

  test "control: a complete brief without its completion time still renders" do
    job = Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).order(:id).first
    job.update_columns(brief_completed_at: nil)
    sign_in_as User.find_by!(email_address: ACCOUNTS.first)
    get staff_job_brief_path(job)
    assert_response :success
  end
end
