require "test_helper"
require_relative "../bank/bank_engine_helpers"

# Independent test pass, slice D (17 Oct 2026): the competency-bank Excel round trip
# (TestCases::BankWorkbook + TestCases::ImportBank) through the real download and upload endpoints.
# Every name, figure and text is invented. Each test names the defect it would catch; the tests
# assert on what the HR Admin receives (the re-parsed workbook, the stored questions), never on source.
class BankWorkbookPassTest < ActionDispatch::IntegrationTest
  include BankEngineHelpers

  XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
  HEADERS = TestCases::BankWorkbook::HEADERS

  setup { bank_setup! }

  # A hand-built workbook. rows are arrays of cell values; types per cell may be given (numbers as numbers).
  def book(rows, headers: HEADERS, types: nil, sheets_before: [], name: "bank.xlsx", escape: true)
    package = Axlsx::Package.new
    package.workbook.escape_formulas = escape
    sheets_before.each { |s| package.workbook.add_worksheet(name: s) { |sh| sh.add_row ["Note sheet placed first"] } }
    package.workbook.add_worksheet(name: "Questions") do |sheet|
      sheet.add_row headers
      rows.each { |r| r.nil? ? sheet.add_row([]) : sheet.add_row(r, types: types || ([:string] * r.size)) }
    end
    file(package.to_stream.read, name)
  end

  def file(bytes, name = "bank.xlsx") = Rack::Test::UploadedFile.new(StringIO.new(bytes.b), XLSX, original_filename: name)

  def mc_row(prompt, link: @activity.description, options: %w[Rp1.000 Rp2.000], correct: "B", section: "Technical")
    [section, "Multiple choice", link, prompt, *options, *([""] * (6 - options.size)), correct, "", "", ""]
  end

  def import(upload) = post(staff_job_question_bank_import_path(@job), params: { file: upload })
  def questions = QuestionBank.latest_for(@job)&.questions&.order(:position).to_a || []
  def snapshot(q) = [q.section, q.kind, q.activity_id, q.competency_id, q.prompt, q.options, q.correct_index, q.anchor_1, q.anchor_3, q.anchor_5]

  def sheet_xml(bytes, part = "xl/worksheets/sheet1.xml")
    xml = nil
    Zip::File.open_buffer(StringIO.new(bytes)) { |zip| xml = zip.find_entry(part).get_input_stream.read }
    xml
  end

  # Catches: export rewriting a value (rounding, re-casing, trimming quotes or newlines), a lost option
  # order or a shifted correct letter, and a leading "=" written as a live formula (formula injection).
  test "round trip through HTTP keeps every value, order and letter, and writes '=' text as text, not a formula" do
    sign_in_as @admin
    tricky = "Pilih \"total\", lalu cek: café, 中文, 🙂\nbaris dua, koma, titik; =SUM(A1:A9)"
    six = ["=HYPERLINK(\"http://evil.example\",\"klik\")", "1000", "+62 811", "-5", "@ref", "Teks, dengan koma"]
    written = ["Role", "Written", @competency.name, "=1+1 describe a hard day", *([""] * 6), "", "lemah \"sekali\"", "cukup,\nbaik", "kuat 🙂"]
    import book([mc_row(tricky, options: six, correct: "F"), written])
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    first = questions.map { |q| snapshot(q) }
    assert_equal 2, first.size
    assert_equal six, first[0][5], "options keep their text and order"
    assert_equal 5, first[0][6], "F is the sixth option"

    get staff_job_question_bank_workbook_path(@job, filled: 1)
    assert_response :success
    xml = sheet_xml(response.body)
    refute_match(/<f>/, xml, "no exported cell is a live formula")
    assert_includes xml, "=HYPERLINK(", "the text is still there, as text"

    import file(response.body, "back.xlsx")
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    again = questions.map { |q| snapshot(q) }
    assert_equal 4, again.size
    assert_equal first, again.last(2), "the re-imported questions are identical to the exported ones"
  end

  # Catches: the shared-strings branch of the reader (what Excel and LibreOffice write; caxlsx writes
  # inline strings by default, so the other tests never reach it) losing or shifting values. Also
  # records the observed behaviour for a HIDDEN row: it is imported like any other row.
  test "a shared-strings workbook imports its values; a hidden row is imported too" do
    sign_in_as @admin
    package = Axlsx::Package.new
    package.use_shared_strings = true
    package.workbook.add_worksheet(name: "Questions") do |sheet|
      sheet.add_row HEADERS
      sheet.add_row mc_row("Shared one, \"quoted\"", options: %w[Alpha Beta Gamma], correct: "C"), types: [:string] * 14
      sheet.add_row(mc_row("Hidden row question"), types: [:string] * 14).hidden = true
    end
    bytes = package.to_stream.read
    assert_includes Zip::File.open_buffer(StringIO.new(bytes)).entries.map(&:name), "xl/sharedStrings.xml", "control: the file uses shared strings"
    import file(bytes)
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal [["Shared one, \"quoted\"", %w[Alpha Beta Gamma], 2], ["Hidden row question", %w[Rp1.000 Rp2.000], 1]],
                 questions.map { |q| [q.prompt, q.options, q.correct_index] }
  end

  # Catches: a numeric cell read as "1000.0" or a float artefact, and an option typed as a number
  # refused or reformatted.
  test "numbers typed in option cells import as the digits shown" do
    sign_in_as @admin
    row = ["Technical", "Multiple choice", @activity.description, "Which amount?", 1000, 2000.5, "", "", "", "", "A", "", "", ""]
    import book([row], types: [:string] * 4 + %i[integer float] + [:string] * 8)
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal %w[1000 2000.5], questions.first.options
  end

  # Catches: a lowercase letter or word refused, and link text matching that breaks on case or padding.
  test "lowercase letter, words and padded link text with other case are accepted" do
    sign_in_as @admin
    row = mc_row("Case test", link: "  #{@activity.description.upcase}  ", correct: "b").tap { |r| r[0] = "technical"; r[1] = "multiple choice" }
    import book([row])
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    q = questions.first
    assert_equal [@activity.id, 1], [q.activity_id, q.correct_index]
  end

  # Catches: header check by position only (two swapped columns would import A as B), and a strict
  # reader that refuses a harmless note column at the end. Control: the same rows with the true header import.
  test "swapped header columns are refused whole; an extra note column at the end is read past" do
    sign_in_as @admin
    swapped = HEADERS.dup.tap { |h| h[4], h[5] = h[5], h[4] }
    import book([mc_row("Q swapped")], headers: swapped)
    assert_response :unprocessable_content
    assert_includes response.body, "header row is not the template"
    assert_empty questions

    import book([mc_row("Q with note") + ["note for my manager"]], headers: HEADERS + ["Note"])
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal ["Q with note"], questions.map(&:prompt)
  end

  # Catches: a blank row in the middle stopping the read, or shifting the row numbers in error messages.
  test "a blank row in the middle is skipped and later errors keep their Excel row number" do
    sign_in_as @admin
    import book([mc_row("Q one"), nil, mc_row("Q bad", link: "Not in this brief")])
    assert_response :unprocessable_content
    assert_includes response.body, "Row 4: &quot;Not in this brief&quot;"
    refute_includes response.body, "Row 3:"
    assert_empty questions, "all or nothing"
  end

  # Catches: the 300-row cap checked after saving, or not at all.
  test "301 question rows are refused before anything is saved" do
    sign_in_as @admin
    import book((1..301).map { |i| mc_row("Q #{i}") })
    assert_response :unprocessable_content
    assert_includes response.body, "The file has 301 questions; upload at most 300"
    assert_empty questions
  end

  # Catches: a link resolved across vacancies (another job's activity text accepted).
  test "an activity of another vacancy is refused" do
    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    other.activities.first.update_columns(description: "Unique activity of the other vacancy 4471")
    sign_in_as @admin
    import book([mc_row("Q cross", link: "Unique activity of the other vacancy 4471")])
    assert_response :unprocessable_content
    assert_includes response.body, "is not an activity of this vacancy"
    assert_empty questions
  end

  # Catches: a sheet placed before "Questions" being read as the questions (or the file refused).
  # Rule since F5 (17 Oct 2026, 12:52): the reader takes the sheet NAMED "Questions" through
  # workbook.xml and its rels. Before F5 this file was refused with a header message (pinned then).
  test "a workbook whose first sheet is a note sheet still imports the sheet named 'Questions'" do
    sign_in_as @admin
    import book([mc_row("Q second sheet")], sheets_before: ["Notes"])
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal ["Q second sheet"], questions.map(&:prompt)
  end

  # Catches: the sheet id from workbook.xml interpolated into an XPath query unescaped, so a quote in
  # the id raises an XPath syntax error (a 500) instead of a refusal the HR Admin can act on.
  test "a quote in the Questions sheet id is refused cleanly, not a 500" do
    sign_in_as @admin
    good = book([mc_row("Q quote id")]).read
    tampered = Zip::OutputStream.write_buffer do |z|
      Zip::File.open_buffer(StringIO.new(good)) do |src|
        src.each do |e|
          body = e.get_input_stream.read
          body = body.sub(/(name="Questions"[^>]*r:id=")([^"]+)"/, "\\1\\2']\"") if e.name == "xl/workbook.xml"
          z.put_next_entry(e.name); z.write(body)
        end
      end
    end.string
    tampered_book = nil
    Zip::File.open_buffer(StringIO.new(tampered)) { |z| tampered_book = z.find_entry("xl/workbook.xml").get_input_stream.read }
    assert_match(/name="Questions"[^>]*r:id="[^"]*'\]"/, tampered_book, "control: the tamper was applied")
    status = begin
      import file(tampered)
      response.status
    rescue StandardError => e
      flunk "500: #{e.class}: #{e.message}"
    end
    assert_includes [302, 422], status
    assert_operator questions.size, :<=, 1, "at most the one row of the file"
  end

  # Catches: two activities that differ only by case resolving silently to the first (F6). Rule since
  # 17 Oct 2026, 12:52: an exact match wins; a case-insensitive match counts only when it is unique.
  test "two activities differing only by case: exact text resolves, a loose match is refused" do
    first, second = @job.activities.first(2)
    assert second, "fixture needs two activities"
    first.update_columns(description: "Reconcile the stock card")
    second.update_columns(description: "RECONCILE THE STOCK CARD")
    sign_in_as @admin
    import book([mc_row("Q loose", link: "reconcile the stock card")])
    assert_response :unprocessable_content
    assert_includes response.body, "is not an activity of this vacancy"
    assert_empty questions

    import book([mc_row("Q exact", link: "RECONCILE THE STOCK CARD")])
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal [second.id], questions.map(&:activity_id), "the exact text picks the second activity, not the first"
  end

  # Catches: content judged by the file name. A Word file renamed .xlsx and a macro workbook renamed
  # .xlsx must both be refused by content, with nothing added.
  test "a .docx or a macro workbook renamed .xlsx is refused" do
    sign_in_as @admin
    docx = Zip::OutputStream.write_buffer do |z|
      z.put_next_entry("[Content_Types].xml"); z.write('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
      z.put_next_entry("word/document.xml"); z.write("<w:document/>")
    end.string
    import file(docx, "bank.xlsx")
    assert_response :unprocessable_content
    # Observed wording: "File type .xlsx is not allowed for this test." (refused, but the reason names
    # the extension the import asks for; reported as a wording finding, not asserted here).
    assert_empty questions

    good = book([mc_row("Q macro")]).read
    macro = Zip::OutputStream.write_buffer do |z|
      Zip::File.open_buffer(StringIO.new(good)) { |src| src.each { |e| z.put_next_entry(e.name); z.write(e.get_input_stream.read) } }
      z.put_next_entry("xl/vbaProject.bin"); z.write("fake macro")
    end.string
    import file(macro, "bank.xlsx")
    assert_response :unprocessable_content
    assert_includes response.body, "it contains a macro"
    assert_empty questions
  end

  # Catches: an oversized (highly compressed) Questions part being inflated in full.
  test "a highly compressed oversized sheet is refused without importing" do
    sign_in_as @admin
    sheet = +'<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
    sheet << (" " * 6_000_000) << "</sheetData></worksheet>"
    good = book([mc_row("Q bomb")]).read
    bomb = Zip::OutputStream.write_buffer do |z|
      Zip::File.open_buffer(StringIO.new(good)) do |src|
        src.each { |e| z.put_next_entry(e.name); z.write(e.name == "xl/worksheets/sheet1.xml" ? sheet : e.get_input_stream.read) }
      end
    end.string
    assert_operator bomb.bytesize, :<, 1.megabyte, "the upload itself is small"
    import file(bomb)
    assert_response :unprocessable_content
    assert_empty questions
  end

  # Catches: an import into a SUBMITTED bank slipping a question past the HR Manager's review.
  test "import into a submitted bank is refused and the submitted version is unchanged" do
    bank = submitted_bank!
    before = bank.questions.count
    sign_in_as @admin
    import book([mc_row("Q late")])
    assert_response :unprocessable_content
    assert_includes response.body, "is submitted for the HR Manager"
    assert_equal before, bank.reload.questions.count
  end

  # Catches: an import that silently creates version n + 1 of an APPROVED bank without a reason, or
  # one that writes into the approved version. Rule since F3 (17 Oct 2026, 12:52): without the form's
  # reason ONE message and no new version; with it the rows go into version n + 1 (a copy of n) and
  # version n is untouched. Before F3 every row repeated "The reason for the new version is required"
  # and the form had no reason field (pinned then).
  test "import into an approved bank: one message without a reason; with it a copied version 2, version 1 unchanged" do
    bank = approved_bank!
    digest = bank.content_digest
    count = bank.questions.count
    sign_in_as @admin
    rows = [mc_row("Q after approval"), mc_row("Q two after approval")]
    import book(rows)
    assert_response :unprocessable_content
    assert_equal 1, response.body.scan("write the reason for the new version").size, "one message, not one per row"
    assert_equal bank.id, QuestionBank.latest_for(@job).id, "no version n + 1"

    post staff_job_question_bank_import_path(@job), params: { file: book(rows), new_version_reason: "Two cash questions added from the workshop" }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    v2 = QuestionBank.latest_for(@job)
    assert_equal [2, "Two cash questions added from the workshop"], [v2.version, v2.new_version_reason]
    assert_equal count + 2, v2.questions.count, "copied questions plus the two imported"
    assert_equal ["Q after approval", "Q two after approval"], v2.questions.order(:position).last(2).map(&:prompt)
    bank.reload
    assert_equal [count, digest, true], [bank.questions.count, bank.content_digest, bank.approved?], "version 1 untouched"
  end

  # Catches: the import authorised by role only (any HR Admin), not by the vacancy's consultant.
  test "an HR Admin who is not the vacancy's consultant cannot import" do
    @job.update!(consultant: staff_user("consultant"))
    sign_in_as @admin
    import book([mc_row("Q outsider")])
    assert_response :unprocessable_content
    assert_includes response.body, "filled in by the consultant assigned to it"
    assert_nil QuestionBank.latest_for(@job)
  end
end
