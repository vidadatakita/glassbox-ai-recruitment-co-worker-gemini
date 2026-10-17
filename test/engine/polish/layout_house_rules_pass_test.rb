require "test_helper"

# Independent test pass (17 Oct 2026): the phone layout and the house rules on the four pages the polish
# touched (vacancy list, vacancy page, applicant page, impact page), checked STRUCTURALLY on the rendered
# HTML. No browser was run: these tests cannot see the actual rendering at 390px.
#
# Why the table rule: workflow.css, inside the phone media query, removes the horizontal scroll of
# ".card-body.table-responsive" (unscoped until 13:10 today, scoped to card bodies holding a stacking
# table since). A plain table that loses that scroll widens the page. Only tables that stack (".table-stack", or the gate table's own
# ".gate-table" rules in technical_test.css) are safe there. A stacking table shows each cell's column
# name from data-label; a cell without it shows a bare value.
#
# House rules (global conventions): the view/detail icon is fa-plus, never fa-eye; no submit is disabled;
# no form opens while another is open (checked on the raw text, because the HTML parser repairs nesting).
class PolishLayoutHouseRulesPassTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    @job = technical_test_job(open_gate: false)
    @application, = applicant!(@job, name: "Bayu Pradipta")
    sign_in_as staff_user("superadmin")
  end

  def pages
    {
      "vacancy list" => staff_jobs_path, "vacancy page" => staff_job_path(@job),
      "applicant page" => staff_application_path(@application), "impact page" => staff_impact_path
    }
  end

  def fetch(path)
    get path
    assert_response :success, path
    response.body
  end

  # Raw-text nesting check: walk the <form ... > and </form> tags in order.
  def max_form_depth(raw)
    depth = 0
    max = 0
    raw.scan(%r{<form\b|</form>}) do |tag|
      depth += tag == "</form>" ? -1 : 1
      max = [max, depth].max
    end
    [max, depth]
  end

  test "house rules on every touched page: no nested form, no disabled submit, no eye icon" do
    pages.each do |name, path|
      raw = fetch(path)
      max, final = max_form_depth(raw)
      assert_equal 1, max, "#{name}: a form opens inside another form" if raw.include?("<form")
      assert_equal 0, final, "#{name}: unbalanced form tags"
      doc = Nokogiri::HTML(raw)
      assert_empty doc.css("i.fa-eye, .fa-eye"), "#{name}: fa-eye used"
      doc.css("button[type=submit], input[type=submit]").each do |b|
        assert_nil b["disabled"], "#{name}: disabled submit #{b.text.squish.inspect}"
      end
      doc.css("button[type=submit][name]").each do |b|
        assert b["value"].present?, "#{name}: named submit #{b['name']} has no value"
      end
    end
  end

  test "detail links on the vacancy list and the vacancy page use the plus icon and carry a title" do
    [staff_jobs_path, staff_job_path(@job)].each do |path|
      doc = Nokogiri::HTML(fetch(path))
      links = doc.css("a[title^='View']")
      assert_operator links.size, :>=, 1, "#{path}: a detail link is drawn"
      links.each { |a| assert a.at_css("i.fa-plus"), "#{path}: #{a['title']} without fa-plus" }
    end
  end

  test "every stacking table gives each data cell its column name" do
    pages.each do |name, path|
      doc = Nokogiri::HTML(fetch(path))
      doc.css("table.table-stack tbody tr").each do |tr|
        cells = tr.css("td")
        next if cells.size == 1 && cells.first["colspan"] # the empty-state row

        cells.drop(1).each do |td|
          next if td["class"].to_s.include?("hris-table-actions")

          assert td["data-label"].present?, "#{name}: a stacked cell without data-label: #{td.text.squish[0, 60].inspect}"
        end
      end
    end
  end

  # A plain table must keep its horizontal scroll on a phone. That holds if the phone rule that removes
  # the scroll applies only to card bodies holding a stacking table (":has(> .table-stack)", as of
  # 13:10 today), or, when the rule is unscoped, if every table in such a card body stacks.
  test "on the four pages, no plain table loses its horizontal scroll on a phone" do
    css = Rails.root.join("app/assets/stylesheets/workflow.css").read
    unscoped = css.match?(/\.card-body\.table-responsive\s*\{[^}]*overflow-x:\s*visible/)
    scoped = css.match?(/\.card-body\.table-responsive:has\(>\s*\.table-stack\)\s*\{[^}]*overflow-x:\s*visible/)
    assert(unscoped || scoped, "control: the phone overflow rule was not found in workflow.css; this test reads the wrong rule")
    offenders = pages.flat_map do |name, path|
      doc = Nokogiri::HTML(fetch(path))
      doc.css(".card-body.table-responsive table").reject { |t| t["class"].to_s.match?(/\b(table-stack|gate-table)\b/) }
         .map { |t| "#{name}: #{t.at_css('thead')&.text&.squish.to_s[0, 50].inspect}" }
    end
    assert_empty offenders, "plain tables that will widen the page on a phone (no browser check run)" if unscoped
  end

  test "the impact source tables label their cells on a phone" do
    raw = fetch(staff_impact_path)
    doc = Nokogiri::HTML(raw)
    rows = doc.css("table.impact-sources tbody tr")
    assert_operator rows.size, :>=, 1, "fixture: the vacancy with an applicant gives a source row"
    rows.each do |tr|
      tr.css("td").drop(1).each do |td|
        assert td["data-label"].present?, "impact source cell without a column name: #{td.text.squish[0, 40].inspect}"
      end
    end
  end

  test "no fixed width wider than a 390px phone in the stylesheets the polish changed" do
    %w[workflow.css staff.css candidate.css].each do |file|
      # Media-query conditions such as "(min-width: 1200px)" are breakpoints, not widths: removed first.
      css = Rails.root.join("app/assets/stylesheets", file).read.gsub(/\(\s*(?:min|max)-width:[^)]*\)/, "")
      css.scan(/(?<![-\w])(?:min-)?width:\s*(\d+)px/).flatten.map(&:to_i).each do |px|
        assert_operator px, :<=, 390, "#{file}: a fixed width of #{px}px"
      end
    end
  end
end
