require "test_helper"
require_relative "engine08_support"

# Engine 08, D53 (GlassBox Team 18:3x): criteria SHOWN on 1-5 (wajib met = 5, not_met = 1; 0 -> 1, 1 -> 2,
# 2 -> 4, 3 -> 5), display only. Attacked: every mapping point and the refusals, screen = xlsx
# sheet "Penilaian Kriteria" in the same order, blind name rule on that sheet, and the S1 score,
# band and sort never reading the 1-5.
class Engine08CriterionScaleTest < ActionDispatch::IntegrationTest
  include Engine08Support

  setup do
    set_retention
    publish_consent
    @job, @s1, @s2 = e8_job
  end

  def judgements(wajib:, sebaiknya:, nilai:)
    [{ "key" => "w1", "tier" => "wajib", "text" => "Syarat wajib uji", "weight" => nil, "judgement" => wajib, "quote" => "S1 Akuntansi", "verified" => true },
     { "key" => "s1", "tier" => "sebaiknya", "text" => "Syarat sebaiknya uji", "weight" => 100, "judgement" => sebaiknya, "quote" => "Menyusun jurnal umum", "verified" => true },
     { "key" => "n1", "tier" => "nilai_tambah", "text" => "Nilai tambah uji", "weight" => nil, "judgement" => nilai, "quote" => "=1+1 kutipan", "verified" => false }]
  end

  test "mapping: every point of D53, and anything else refused rather than printed as a number" do
    s = ScreeningReport::CriterionScale
    assert_equal 5, s.of("wajib", "met")
    assert_equal 1, s.of("wajib", "not_met")
    { "0" => 1, "1" => 2, "2" => 4, "3" => 5 }.each do |j, v|
      assert_equal v, s.of("sebaiknya", j), "sebaiknya #{j}"
      assert_equal v, s.of("nilai_tambah", j), "nilai_tambah #{j}"
    end
    [["wajib", "3"], ["wajib", nil], ["sebaiknya", "met"], ["sebaiknya", "4"], ["nilai_tambah", "-1"], ["sebaiknya", nil]].each do |tier, j|
      assert_raises(ArgumentError, "#{tier}/#{j.inspect} printed a number") { s.of(tier, j) }
    end
    assert_includes s::RULE, "must-have met = 5"
  end

  test "detail screen = xlsx 'Criteria Scoring', same order, values and escaped quotes; blind sheet carries no name" do
    names = { "Ani Uji" => %w[met 3 2], "Budi Uji" => %w[not_met 0 1] }
    names.each do |name, (w, s, n)|
      _a, p1, _p2 = e8_applicant(@job, @s1, @s2, name:)
      e8_result(p1, score: name == "Ani Uji" ? 80 : 30, judgements: judgements(wajib: w, sebaiknya: s, nilai: n))
    end
    # Superadmin: the only role that sees names before the gate (three-role model, 17 Oct 2026).
    e8_judge_calibration!(@job) # judged CVs are not hidden from the superadmin (18 Oct 2026)
    sign_in_as staff_user("superadmin")
    board = e8_board(@job, staff_user("superadmin"))
    screen = board.rows.flat_map do |row|
      get staff_job_screening_report_candidate_path(@job, row.application.id)
      css_select("table.report-criteria tbody tr").map { |tr| [row.candidate.name, tr.css("td")[0].text.strip, tr.at("td.report-criteria__score").text.strip.to_i] }
    end
    assert_equal [["Ani Uji", "Syarat wajib uji", 5], ["Ani Uji", "Syarat sebaiknya uji", 5], ["Ani Uji", "Nilai tambah uji", 4],
                  ["Budi Uji", "Syarat wajib uji", 1], ["Budi Uji", "Syarat sebaiknya uji", 1], ["Budi Uji", "Nilai tambah uji", 2]], screen
    get staff_job_screening_report_export_path(@job)
    sheet = criteria_sheet(response.body)
    data = sheet[3, 6]
    assert_equal screen, data.map { [it[1], it[2], it[4].to_i] }, "xlsx criteria sheet differs from the screen"
    assert_equal ["'=1+1 kutipan"], data.map { it[6] }.uniq & ["'=1+1 kutipan"], "quote escaped once"
    sign_out
    sign_in_as staff_user("hr_admin")
    get staff_job_screening_report_export_path(@job)
    blind = criteria_sheet(response.body)
    refute blind.flatten.compact.any? { it.include?("Ani Uji") || it.include?("Budi Uji") }, "name on the blind criteria sheet"
    assert_equal ["Candidate 01", "Candidate 02"], blind[3, 6].map { it[1] }.uniq.sort
  end

  test "the 1-5 never feeds the S1 score, the band or the sort: identical judgements, different scores order by score" do
    _a, p1, _ = e8_applicant(@job, @s1, @s2, name: "Tinggi Skala Uji")
    _b, p2, _ = e8_applicant(@job, @s1, @s2, name: "Rendah Skala Uji")
    e8_result(p1, score: 30, judgements: judgements(wajib: "met", sebaiknya: "3", nilai: "2"))
    e8_result(p2, score: 70, judgements: judgements(wajib: "not_met", sebaiknya: "0", nilai: "0"))
    e8_judge_calibration!(@job) # the consultant judges calibration; judged CVs are not hidden
    rows = e8_board(@job, staff_user("consultant")).rows
    assert_equal ["Rendah Skala Uji", "Tinggi Skala Uji"], rows.map { it.candidate.name }
    assert_equal [4, 2], rows.map(&:band)
    refute_match(/CriterionScale/, File.read(Rails.root.join("app/models/screening/score.rb")))
    refute_match(/CriterionScale/, File.read(Rails.root.join("app/presenters/screening_report_board.rb")))
  end

  def criteria_sheet(body)
    Zip::File.open_buffer(StringIO.new(body)) do |zip|
      strings = Nokogiri::XML(zip.read("xl/sharedStrings.xml")).remove_namespaces!.css("si").map { |si| si.css("t").map(&:text).join }
      names = Nokogiri::XML(zip.read("xl/workbook.xml")).remove_namespaces!.css("sheet").map { it["name"] }
      idx = names.index("Criteria Scoring") or flunk("no sheet 'Criteria Scoring': #{names}")
      xml = Nokogiri::XML(zip.read("xl/worksheets/sheet#{idx + 1}.xml")).remove_namespaces!
      return xml.css("sheetData row").map { |r| r.css("c").map { |c| c["t"] == "s" ? strings[c.at("v").text.to_i] : c.at("v")&.text } }
    end
  end
end
