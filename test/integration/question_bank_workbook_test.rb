require "test_helper"

# Competency bank Excel round trip (slice D, 17 Oct 2026): the template downloads with the brief's
# rows as lists; a filled workbook imports all rows or none (each problem with its row number); a
# downloaded bank imports back unchanged into a new draft.
class QuestionBankWorkbookTest < ActionDispatch::IntegrationTest
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    @activity = @job.activities.first
    @competency = @job.competencies.first
  end

  def workbook(rows)
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Questions") do |sheet|
      sheet.add_row TestCases::BankWorkbook::HEADERS
      rows.each { |r| sheet.add_row r, types: [:string] * r.size }
    end
    Rack::Test::UploadedFile.new(StringIO.new(package.to_stream.read), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                 original_filename: "bank.xlsx")
  end

  def choice_row(prompt, link: @activity.description, section: "Technical")
    [section, "Multiple choice", link, prompt, "Rp1.000", "Rp2.000", "", "", "", "", "B", "", "", ""]
  end

  test "the template downloads as an xlsx with the header row" do
    sign_in_as @admin
    get staff_job_question_bank_workbook_path(@job)
    assert_response :success
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    rows = TestCases::BankWorkbook.read(response.body)
    assert_empty rows, "the template has no question rows"
  end

  test "a filled workbook imports every row, marked as imported, with the right answer letter" do
    sign_in_as @admin
    written = ["Role", "Written", @competency.name, "Describe a hard day.", "", "", "", "", "", "", "", "weak", "ok", "strong"]
    post staff_job_question_bank_import_path(@job), params: { file: workbook([choice_row("Q one"), written]) }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    questions = QuestionBank.latest_for(@job).questions
    assert_equal [["Q one", "import", 1], ["Describe a hard day.", "import", nil]], questions.map { |q| [q.prompt, q.source, q.correct_index] }
  end

  test "one wrong row adds nothing and every problem names its row" do
    sign_in_as @admin
    bad_link = choice_row("Q two", link: "Not an activity")
    bad_answer = choice_row("Q three").tap { |r| r[10] = "E" }
    post staff_job_question_bank_import_path(@job), params: { file: workbook([choice_row("Q one"), bad_link, bad_answer]) }
    assert_response :unprocessable_content
    assert_includes response.body, "Row 3: &quot;Not an activity&quot; is not an activity"
    assert_includes response.body, "Row 4:"
    assert_nil QuestionBank.latest_for(@job)&.questions&.first, "nothing added"
  end

  test "a file that is not the template is refused with the reason" do
    sign_in_as @admin
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Other") { |s| s.add_row %w[Name Value] }
    file = Rack::Test::UploadedFile.new(StringIO.new(package.to_stream.read), "application/octet-stream", original_filename: "other.xlsx")
    post staff_job_question_bank_import_path(@job), params: { file: }
    assert_response :unprocessable_content
    assert_includes response.body, "header row is not the template"
  end

  test "round trip: a downloaded bank imports back with the same questions" do
    sign_in_as @admin
    post staff_job_question_bank_import_path(@job), params: { file: workbook([choice_row("Q one"), choice_row("Q two")]) }
    get staff_job_question_bank_workbook_path(@job, filled: 1)
    exported = TestCases::BankWorkbook.read(response.body)
    assert_equal ["Q one", "Q two"], exported.map { |r| r["Question"] }
    assert_equal %w[B B], exported.map { |r| r["Correct option (A-F)"] }
    file = Rack::Test::UploadedFile.new(StringIO.new(response.body), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", original_filename: "back.xlsx")
    post staff_job_question_bank_import_path(@job), params: { file: }
    assert_redirected_to staff_job_test_case_step_path(@job, anchor: "question-bank")
    assert_equal 4, QuestionBank.latest_for(@job).questions.count
  end

  test "an HR Manager cannot import" do
    sign_in_as staff_user("reviewer")
    post staff_job_question_bank_import_path(@job), params: { file: workbook([choice_row("Q one")]) }
    assert_response :unprocessable_content
    assert_nil QuestionBank.latest_for(@job)
  end
end
