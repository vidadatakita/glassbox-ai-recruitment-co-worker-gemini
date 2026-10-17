require "test_helper"

# Vacancy list filter (17 Oct 2026): position search, status, package, next-action owner. GET form,
# each value once, "Filter" button, unknown values ignored, figures describe the rows shown.
class VacancyListFilterTest < ActionDispatch::IntegrationTest
  setup do
    with_env("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil) { capture_io { Rails.application.load_seed } }
    sign_in_as User.find_by!(email_address: "admin@glassbox.example")
  end

  def titles = css_select("tbody tr td[data-label='Vacancy']").map { |td| td.text.squish }

  test "the filter is its own GET form with a Filter button, never nested; unfiltered shows every vacancy" do
    get staff_jobs_path
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"
    form = doc.at_css("form.job-list-filter")
    assert_equal "get", form["method"]
    assert_equal "Filter", form.at_css("button[type=submit]").text.squish
    assert_equal 1, form.css("[name='q']").size, "q travels once"
    # Multi-select (Vida, 17 Oct 2026): each list is checkboxes named field[], one box per value, each
    # value once; no single-value field of the same name competes with them.
    %w[status package owner city].each do |name|
      boxes = form.css("input[type=checkbox][name='#{name}[]']")
      assert_operator boxes.size, :>=, 1, "#{name} offers its values"
      assert_equal boxes.map { |b| b["value"] }.uniq.size, boxes.size, "each #{name} value appears once"
      assert_empty form.css("[name='#{name}']"), "#{name} has no second, single-value field"
    end
    assert_equal Job.count, titles.size
    refute_includes response.body, "(filtered)"
  end

  test "search by position narrows the rows and the figures say so" do
    get staff_jobs_path(q: "accounting")
    assert_equal 1, titles.size
    assert titles.first.start_with?("Accounting Supervisor")
    assert_includes response.body, "Showing 1 of #{Job.count} vacancies"
    assert_includes response.body, "received by the vacancies shown"
  end

  test "status, package and owner filters agree with each vacancy's next step" do
    steps = Job.all.to_h { |j| [j.id, VacancyNextStep.for(j, ApplicationWindow.new(j))] }
    JobListFilter::STATUSES.each_key do |status|
      get staff_jobs_path(status:)
      expected = Job.all.select { |j| steps[j.id].status.to_s == status }.map(&:title).sort
      assert_equal expected, titles.map { |t| Job.all.map(&:title).find { |title| t.start_with?(title) } }.sort, "status #{status}"
    end
    get staff_jobs_path(package: "3")
    assert_equal Job.where(package: 3).count, titles.size
    get staff_jobs_path(owner: "nobody")
    assert_equal Job.all.count { |j| steps[j.id].owner == :nobody }, titles.size
  end

  test "an unknown value is ignored, and an empty result says how to get back" do
    get staff_jobs_path(status: "bogus", package: "9")
    assert_equal Job.count, titles.size
    get staff_jobs_path(q: "no such vacancy title")
    assert_includes response.body, "No vacancy matches this filter"
    assert_select "a[href='#{staff_jobs_path}']", text: /Reset/
  end
end
