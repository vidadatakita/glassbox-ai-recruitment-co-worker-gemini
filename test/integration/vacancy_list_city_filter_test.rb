require "test_helper"

# Vacancy list, 17 Oct 2026 (Vida: "add filter by city placement"). A vacancy matches when ANY of its
# placements is the chosen city; the options are the cities the org's vacancies are placed in, and an
# unknown city is ignored (shows all), never an error.
class VacancyListCityFilterTest < ActionDispatch::IntegrationTest
  setup do
    @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] }
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    @jobs = Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).order(:id).to_a
    @jobs.first.update_columns(placements: ["Surabaya", "Makassar"])
    @jobs.drop(1).each { |job| job.update_columns(placements: ["Kota Tangerang"]) }
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
  end
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  def listed_titles = css_select("tbody tr td[data-label='Vacancy']").map { |td| td.text.squish }

  test "a city keeps only the vacancies placed there, including a second placement" do
    get staff_jobs_path, params: { city: "Makassar", commit: "Filter" }
    assert_response :success
    assert_select "input[name='city[]'][value='Makassar'][checked]", 1
    assert_equal 1, listed_titles.size
    assert_match @jobs.first.title, listed_titles.first

    get staff_jobs_path, params: { city: "kota tangerang" }
    assert_equal @jobs.size - 1, listed_titles.size, "the match ignores letter case"
  end

  test "several cities and several position terms widen the list (any of them matches)" do
    get staff_jobs_path, params: { city: %w[Makassar Kota\ Tangerang] }
    assert_equal @jobs.size, listed_titles.size
    get staff_jobs_path, params: { q: "#{@jobs.first.title.split.first}, #{@jobs.last.title.split.first}" }
    assert_operator listed_titles.size, :>=, 2
    assert(listed_titles.all? { |t| t.include?(@jobs.first.title.split.first) || t.include?(@jobs.last.title.split.first) })
  end

  test "control: no city or an unknown city lists every vacancy" do
    get staff_jobs_path
    all = listed_titles.size
    assert_operator all, :>=, @jobs.size
    assert_select "input[name='city[]']", 3 # Kota Tangerang, Makassar, Surabaya
    get staff_jobs_path, params: { city: "Atlantis" }
    assert_response :success
    assert_equal all, listed_titles.size
  end
end
