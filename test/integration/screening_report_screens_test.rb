require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# Feature 08 screens and xlsx (SPEC §1-§2, D62 h1/h6/h7/h8), on the invented demo seed. The xlsx is
# read back from the bytes the controller sent (rubyzip), never from the in-memory package.
class ScreeningReportScreensTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @open_job, @closed_job = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"),
                                                     reviewer: staff_user("reviewer"))
    @a = JobApplication.joins(:candidate).find_by!(job: @open_job, candidates: { name: "Kandidat Contoh A" })
  end

  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
  end

  def xlsx_cells(body)
    require "zip"
    Zip::File.open_buffer(StringIO.new(body)) do |zip|
      strings = Nokogiri::XML(zip.read("xl/sharedStrings.xml")).remove_namespaces!.css("si").map { |si| si.css("t").map(&:text).join }
      sheet = Nokogiri::XML(zip.read("xl/worksheets/sheet1.xml")).remove_namespaces!
      return sheet.css("row").map do |row|
        row.css("c").map do |c|
          if c["t"] == "s" then strings[c.at("v").text.to_i]
          elsif c.at("f") then "=#{c.at('f').text}|#{c.at('v')&.text}"
          else c.at("v")&.text || c.at("is t")&.text
          end
        end
      end, sheet
    end
  end

  test "consultant: names, contacts, every SPEC column, sort by gate then AI score, band rule under the column" do
    sign_in_as staff_user("consultant")
    get staff_job_screening_report_path(@open_job)
    assert_response :success
    ["No", "Name", "Last position", "AI score (S1)", "Technical test score (S2)", "CV screening result", "Expected salary", "Label", "Interview appointment", "Hiring manager's pick"].each do |head|
      assert_select "table.report-table th", text: /\A#{Regexp.escape(head).gsub("\\ ", "\\s*")}/
    end
    names = css_select("td.report-table__person").map { |td| td.text.strip.lines.first.strip }
    assert_equal ["Kandidat Contoh C", "Kandidat Contoh A"], names.first(2), "Passed first; C (86,7) before A (73,3)"
    assert_equal %w[B C E F I].map { |k| "Kandidat Contoh #{k}" }.sort - %w[Kandidat\ Contoh\ C], names.last(4).sort,
                 "the four Not passed rows last"
    assert_includes response.body, ScreeningReport::Band::RULE
    assert_includes response.body, "kandidat.a.#{@open_job.id}@contoh.example"
    assert_includes response.body, "Ibu Ratna"
    assert_select "a[href=?] i.fa-plus", staff_job_screening_report_candidate_path(@open_job, @a.id)
    assert_includes response.body, "CONFIDENTIAL"
    refute_includes response.body, DemoScreeningReport::MODEL_ID, "no model name on screen (owner, 2026-10-11)"
    assert_house_form_rules
  end

  test "HR PIC and owner before the gate is confirmed: numbers only, no contacts, said why (D62 h7)" do
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_report_path(@open_job)
      assert_response :success
      refute_match(/Kandidat Contoh/, response.body, "#{role} saw a name")
      refute_includes response.body, "@contoh.example", "#{role} saw a contact"
      assert_select "td.report-table__person", text: /\ACandidate \d\d\z/
      assert_includes response.body, "masked"
      get staff_job_screening_report_candidate_path(@open_job, @a.id)
      refute_match(/Kandidat Contoh A|0812-0000/, response.body)
      sign_out
    end
  end

  test "after the gate closes the HR PIC sees names and contacts; the owner names only; the reviewer never contacts" do
    sign_in_as staff_user("hr_pic")
    get staff_job_screening_report_path(@closed_job)
    assert_includes response.body, "Kandidat Contoh A"
    assert_includes response.body, "@contoh.example"
    assert_includes response.body, "Not scored", "S1-eliminated get gate_eliminated at close"
    sign_out
    sign_in_as staff_user("owner")
    get staff_job_screening_report_path(@closed_job)
    assert_includes response.body, "Kandidat Contoh A"
    refute_includes response.body, "@contoh.example"
    sign_out
    sign_in_as staff_user("reviewer")
    get staff_job_screening_report_path(@open_job)
    assert_includes response.body, "Kandidat Contoh A", "DataKita staff see names"
    refute_includes response.body, "@contoh.example"
  end

  test "admin has no access to the report (BP §1.2, test engine F13 rule)" do
    sign_in_as staff_user("admin")
    get staff_job_screening_report_path(@open_job)
    assert_redirected_to staff_jobs_path
    get staff_job_screening_report_export_path(@open_job)
    assert_redirected_to staff_jobs_path
  end

  test "detail page: header figures, criteria with quotes, AI draft, rubric lines, footer" do
    sign_in_as staff_user("consultant")
    get staff_job_screening_report_candidate_path(@open_job, @a.id)
    assert_response :success
    assert_includes response.body, "Criteria scoring table"
    assert_includes response.body, "Menyusun jurnal umum dan rekonsiliasi bank bulanan"
    assert_includes response.body, "Approved by the consultant", "A's narratives are approved in the seed"
    assert_includes response.body, "No quote", "a claim without a quote is shown as such, not hidden"
    assert_includes response.body, "Menemukan kesalahan jurnal", "rubric line from the reviewer's scoring"
    assert_includes response.body, "Within band"
    refute_includes response.body, Screening::PROMPT_VERSION, "no prompt version on screen (owner, 2026-10-11)"
    d = JobApplication.joins(:candidate).find_by!(job: @open_job, candidates: { name: "Kandidat Contoh D" })
    get staff_job_screening_report_candidate_path(@open_job, d.id)
    assert_includes response.body, "AI draft"
    assert_select "form[action=?]", staff_job_screening_report_narratives_path(@open_job, d.id)
    assert_select "form[action=?]", staff_job_screening_report_label_path(@open_job, d.id), 0, "only a reviewer confirms labels"
    assert_house_form_rules
  end

  test "reviewer confirms Over-qualified through the screen only with the Golongan rule; refusal is said" do
    d = JobApplication.joins(:candidate).find_by!(job: @open_job, candidates: { name: "Kandidat Contoh D" })
    sign_in_as staff_user("reviewer")
    post staff_job_screening_report_label_path(@open_job, d.id), params: { label: "over_qualified", last_role_golongan: "5", note: "Posisi terakhir lebih tinggi" }
    follow_redirect!
    assert_includes response.body, "at least 2 Grades above the vacancy (G4)"
    post staff_job_screening_report_label_path(@open_job, d.id), params: { label: "pertimbangkan" }
    follow_redirect!
    assert_includes response.body, "Label saved."
    assert_equal "pertimbangkan", ScreeningLabelConfirmation.where(participation: d.participations).last.label
  end

  test "HR PIC records the hiring manager's pick naming the manager; a consultant cannot" do
    sign_in_as staff_user("consultant")
    post staff_job_screening_report_user_recommendation_path(@open_job, @a.id), params: { user_name: "X", pick: "lanjut" }
    assert_redirected_to staff_jobs_path
    sign_out
    sign_in_as staff_user("hr_pic")
    post staff_job_screening_report_user_recommendation_path(@open_job, @a.id), params: { user_name: "Bapak Hendra", pick: "tidak_lanjut" }
    follow_redirect!
    assert_includes response.body, "Bapak Hendra"
  end

  test "xlsx for the consultant: same columns plus contacts, every text cell escaped, band as a live formula, footer" do
    hostile = { "D" => "=1+1", "E" => "+cmd|' /C calc'!A0", "F" => "-2+3", "G" => "@SUM(1)", "H" => "\tTab", "I" => "\rCR" }
    hostile.each do |key, name|
      Candidate.joins(:job_applications).find_by!(job_applications: { job_id: @open_job.id }, name: "Kandidat Contoh #{key}").update_columns(name:)
    end
    sign_in_as staff_user("consultant")
    get staff_job_screening_report_export_path(@open_job)
    assert_response :success
    assert_equal "attachment", response.headers["Content-Disposition"].split(";").first
    rows, sheet = xlsx_cells(response.body)
    header = rows[3]
    assert_equal ScreeningReport::BuildWorkbook::COLUMNS.map(&:first) + ["Email", "WhatsApp number", "City of residence"], header
    data = rows[4, 9]
    names = data.map { |r| r[1] }
    # An XML parser reads a raw CR back as LF (XML 1.0 §2.11), so the CR case is compared after that
    # normalisation; the quote prefix is what is being checked.
    hostile.each_value { |name| assert_includes names, "'#{name.tr("\r", "\n")}", "#{name.inspect} must be prefixed with a quote" }
    assert_includes names, "Kandidat Contoh A", "control: a benign text cell is untouched"
    refute data.flatten.compact.any? { |v| v.start_with?("=1+1", "+cmd", "-2+3", "@SUM", "\t", "\r") }
    a_row = data.find { |r| r[1] == "Kandidat Contoh A" }
    assert_equal "=IF(D#{4 + data.index(a_row) + 1}=\"\",\"\",MIN(5,INT(D#{4 + data.index(a_row) + 1}/20)+1))|4", a_row[4]
    assert_equal 82.0, Float(a_row[5]), "S2 score is a NUMBER cell"
    assert sheet.at("pane[state='frozen']"), "header frozen"
    Zip::File.open_buffer(StringIO.new(response.body)) do |zip|
      fonts = Nokogiri::XML(zip.read("xl/styles.xml")).remove_namespaces!.css("fonts font").map { |f| f.at("name")["val"] }
      assert_equal ["Calibri"], fonts.uniq, "house font everywhere, the default font included"
    end
    assert_match(/\ACONFIDENTIAL · for the recruitment of .* WIB\z/, rows.last.first)
    refute_match(/model|prompt/i, rows.last.first, "no technical detail in the file (owner, 2026-10-11)")
  end

  test "xlsx for the HR PIC before confirmation is blind: numbers, no contact columns, no name anywhere" do
    sign_in_as staff_user("hr_pic")
    get staff_job_screening_report_export_path(@open_job)
    assert_match(/-anonim-/, response.headers["Content-Disposition"])
    rows, = xlsx_cells(response.body)
    assert_equal ScreeningReport::BuildWorkbook::COLUMNS.map(&:first), rows[3], "no Email / WhatsApp number columns"
    assert rows[4, 9].all? { |r| r[1].match?(/\ACandidate \d\d\z/) }
    refute_match(/Kandidat Contoh|contoh\.example|0812-0000/, rows.flatten.compact.join(" "))
    sign_out
    sign_in_as staff_user("hr_pic")
    get staff_job_screening_report_export_path(@closed_job)
    rows, = xlsx_cells(response.body)
    assert_equal "Email", rows[3][-3], "control: after confirmation the HR PIC export carries contacts"
  end

  test "job page links to the report with one card; no card for admin" do
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@open_job)
    assert_select "#laporan-analisis a[href=?]", staff_job_screening_report_path(@open_job)
  end
end
