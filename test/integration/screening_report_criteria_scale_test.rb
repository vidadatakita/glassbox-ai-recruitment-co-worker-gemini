require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# D53 on the screen and in the xlsx: the 1-5 per criterion, the original judgement beside it, and
# the mapping sentence under both. Demo seed A: wajib met, sebaiknya 3 and 1, nilai tambah 2.
class ScreeningReportCriteriaScaleTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @job, = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
    @a = JobApplication.joins(:candidate).find_by!(job: @job, candidates: { name: "Kandidat Contoh A" })
    sign_in_as staff_user("consultant")
  end

  test "detail page: 1-5 beside the original judgement, mapping stated under the table" do
    get staff_job_screening_report_candidate_path(@job, @a.id)
    rows = css_select("table.report-criteria tbody tr").map { |tr| tr.css("td").map { |td| td.text.strip } }
    assert_equal [["5", "Met"], ["5", "3 of 3"], ["2", "1 of 3"], ["4", "2 of 3"]], rows.map { |r| r[2, 2] }
    assert_includes response.body, ScreeningReport::CriterionScale::RULE
    assert_equal BigDecimal("73.3"), ScreeningResult.current_for(@a.participations.select(:id)).first.score, "score unchanged"
  end

  test "xlsx sheet Criteria Scoring: same numbers, original judgement, mapping row, escaped text" do
    get staff_job_screening_report_export_path(@job)
    require "zip"
    Zip::File.open_buffer(StringIO.new(response.body)) do |zip|
      strings = Nokogiri::XML(zip.read("xl/sharedStrings.xml")).remove_namespaces!.css("si").map { |si| si.css("t").map(&:text).join }
      sheet = Nokogiri::XML(zip.read("xl/worksheets/sheet2.xml")).remove_namespaces!
      rows = sheet.css("row").map { |r| r.css("c").map { |c| c["t"] == "s" ? strings[c.at("v").text.to_i] : c.at("v")&.text } }
      assert_equal ["No", "Name", "Requirement", "Tier", "Score (1–5)", "AI advice", "CV quote"], rows[2]
      a_rows = rows.select { |r| r[1] == "Kandidat Contoh A" }
      assert_equal [%w[5 Met], ["5", "3 of 3"], ["2", "1 of 3"], ["4", "2 of 3"]], a_rows.map { |r| r[4, 2] }
      assert_equal ScreeningReport::CriterionScale::RULE, rows[-2].first
    end
  end
end
