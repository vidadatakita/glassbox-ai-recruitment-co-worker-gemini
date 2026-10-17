require "test_helper"

# Applicant page, 17 Oct 2026 (Vida: clicking a step of "Applicant progress" shows what belongs to that
# step). Every step that links must point at a section that is on the same page, or the click scrolls
# nowhere; the vacancy page's stepper draws no links (control: the shared partial is unchanged there).
class ApplicantProgressLinksTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "each linked step opens a section that exists on the page; CV screening steps open the S1 card" do
    job = Job.find_by!(title: "Accounting Supervisor")
    application = job.job_applications.where.not(candidate_id: nil).order(:id).first
    s1 = application.participations.joins(:stage).find_by!(stages: { code: "S1" })
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
    get staff_application_path(application)
    assert_response :success

    links = css_select("#applicant-progress a.hiring-progress__link[data-open-section]")
    assert_operator links.size, :>=, 5, "the applied, CV screening and stage steps link to their sections"
    links.each do |link|
      id = link["href"].delete_prefix("#")
      assert_equal 1, css_select("[id='#{id}']").size, "step link #{link['href']} has no section on the page"
    end
    hrefs = links.map { |l| l["href"] }
    assert_includes hrefs, "#contact-files"
    assert_includes hrefs, "#stage-#{s1.id}-decision"
    assert_includes hrefs, "#job-offer"
  end

  # 17 Oct 2026, applicant 29: the salary form opens only after the last stage's step decision, and the
  # section used to be simply missing, so the superadmin could not tell why. Now a "not open yet" card
  # holds its place and links to the decision that opens it; the stepper never says "Next: Salary
  # agreed" while that decision is open.
  test "salary not open yet: the superadmin sees why and a link to the decision; the stepper does not skip it" do
    job = Job.find_by!(title: "Accounting Supervisor")
    application = job.job_applications.where.not(candidate_id: nil).order(:id).find { |a| !Progression::Salary.ready?(a) && Progression::Salary.last_step(a) }
    assert application, "the seed has an applicant whose salary is not open yet"
    last = Progression::Salary.last_step(application)
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
    get staff_application_path(application)
    assert_response :success
    assert_select "#salary.salary-waiting", 1
    assert_select "#salary a[href='#stage-#{last.id}-decision'][data-open-section]", 1
    assert_select "[id='stage-#{last.id}-decision']", 1, "the decision the salary card links to is on the page"
    assert_select "#salary form", 0, "no salary form before the decision"
    refute_match(/Next: Salary agreed/, css_select("#applicant-progress .hris-form-card__header p").text)
  end

  # Vacancy page, 17 Oct 2026 (Vida: the same behaviour as the applicant page): every Hiring progress
  # step links to a section on the page, and every section folds with a state chip.
  test "vacancy page: each step opens a section that exists; the sections fold with a state" do
    job = Job.find_by!(title: "Accounting Supervisor")
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
    get staff_job_path(job)
    assert_response :success
    links = css_select("#hiring-progress a.hiring-progress__link[data-open-section]")
    assert_equal css_select("#hiring-progress .hiring-progress__step").size, links.size, "every step is clickable"
    links.each do |link|
      id = link["href"].delete_prefix("#")
      assert_equal 1, css_select("[id='#{id}']").size, "step link #{link['href']} has no section on the page"
    end
    %w[vacancy-brief applicant-portal screening applicants portal-history].each do |id|
      assert_select "details##{id}.section-fold > summary .stage-card__work", 1
    end
    assert_select "details.section-fold details.section-fold", 0, "folds are not nested"
  end

  test "control: the brief page's stepper has no section links" do
    job = Job.find_by!(title: "Accounting Supervisor")
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
    get staff_job_brief_path(job)
    assert_response :success
    assert_select ".hiring-progress a.hiring-progress__link", 0
  end
end
