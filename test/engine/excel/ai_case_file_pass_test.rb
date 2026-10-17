require "test_helper"

# Independent test pass, slice D (17 Oct 2026): the AI case co-worker (TestCases::DraftCaseFile and
# TestCasesController#ai_case / #ai_case_file / #save with case_saran). Every name, figure and text is
# invented. The answer key carries unique markers so its absence can be checked in EVERY part of the
# applicant's .xlsx (sheets, shared strings, document properties), not only in the visible cells.
class AiCaseFilePassTest < ActionDispatch::IntegrationTest
  KEY_WHAT = "KEYWHAT-5521 total ignores the discount".freeze
  KEY_CORRECT = "KEYCORR-5521".freeze

  # Returns the case-file proposal for the case schema, the case study text otherwise. rows/columns/title
  # can be replaced per test.
  class FakeClient
    attr_reader :calls

    def initialize(case_data) = (@case_data = case_data) && (@calls = 0)

    def generate(system:, schema:, content:)
      @calls += 1
      text = if schema.dig(:properties, :planted)
               @case_data
             else
               { instructions: "Check the stock journal and correct every wrong total.", time_limit_minutes: 30, answer_types: ["xlsx"],
                 criteria: [{ activity: 1, name: "Finds wrong totals", weight: 100, anchor_1: "none", anchor_3: "some", anchor_5: "all" }] }
             end
      Screening::AiClient::Reply.new(model: "test-model", text: text.to_json, input_tokens: 5, output_tokens: 7)
    end
  end

  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @consultant = staff_user("consultant")
    @job.update!(consultant: @consultant)
  end

  def case_data(rows: nil, columns: %w[Date Item Qty Price Total], title: "Stock journal, October 2026")
    rows ||= (1..6).map { |i| ["2026-10-0#{i}", "Item #{i}", "2", "1000", i == 2 ? "1800" : "2000"] }
    { title:, columns:, rows:, planted: [{ row: 2, activity: 1, what: KEY_WHAT, correct: KEY_CORRECT }] }
  end

  def draft!(data = case_data)
    client = FakeClient.new(data)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, ->(*, **) { client }) { post staff_job_test_case_ai_case_path(@job) }
    end
    client
  end

  def ids_from(location) = [location[/case_saran=(\d+)/, 1], location[/[?&]saran=(\d+)/, 1]]

  def parts(bytes)
    out = {}
    Zip::File.open_buffer(StringIO.new(bytes)) { |zip| zip.each { |e| out[e.name] = e.get_input_stream.read } }
    out
  end

  # Status of one request; an unrescued exception counts as the 500 an operator would see.
  def status_of
    yield
    response.status
  rescue StandardError => e
    @raised = e
    500
  end

  # Catches: the answer key written into ANY part of the applicant's file (a third sheet, a comment,
  # a document property), and a sheet beyond Instructions + Data.
  test "the applicant's file carries no answer key in any part and only the two sheets" do
    sign_in_as @consultant
    draft!
    case_id, saran = ids_from(response.location)
    get staff_job_test_case_ai_case_file_path(@job, case_id, saran:)
    assert_response :success
    files = parts(response.body)
    assert files.values.join.include?("Item 2"), "control: the data rows are in the file"
    leaks = files.select { |_, body| body.include?("KEYWHAT-5521") || body.include?(KEY_CORRECT) }.keys
    assert_empty leaks, "answer key found in #{leaks.inspect}"
    sheets = files["xl/workbook.xml"].scan(/<sheet [^>]*name="([^"]+)"/).flatten
    assert_equal %w[Instructions Data], sheets
  end

  # Catches: AI text starting with "=" written as a live formula (formula injection into the file the
  # applicant opens), in the data, the headings or the title.
  test "AI values starting with '=' are written as text, never as formulas" do
    sign_in_as @consultant
    rows = (1..6).map { |i| ["=HYPERLINK(\"http://evil.example/#{i}\",\"open\")", "Item #{i}", "=1+#{i}", "1000", "2000"] }
    draft!(case_data(rows:, columns: ["=SUM(A1:A9)", "Item", "Qty", "Price", "Total"], title: "=cmd|' /C calc'!A0"))
    case_id, saran = ids_from(response.location)
    get staff_job_test_case_ai_case_file_path(@job, case_id, saran:)
    files = parts(response.body)
    sheets = files.select { |name, _| name.match?(%r{\Axl/worksheets/sheet\d+\.xml\z}) }
    assert_equal 2, sheets.size
    sheets.each { |name, xml| refute_match(/<f[ >]/, xml, "#{name} holds a live formula") }
    assert files.values.join.include?("=HYPERLINK("), "control: the text itself is kept"
  end

  # Catches: a protected attribute in the AI's data reaching the proposal.
  test "a protected attribute in the AI's rows stores no proposal" do
    sign_in_as @consultant
    rows = (1..6).map { |i| ["2026-10-0#{i}", i == 4 ? "Female staff only" : "Item #{i}", "2", "1000", "2000"] }
    assert_no_difference -> { BriefSuggestion.where(job: @job).count { |s| s.payload.to_h.key?("case_file") } } do
      draft!(case_data(rows:))
    end
    refute_match(/case_saran=/, response.location.to_s)
  end

  # Catches: an HR Admin who is not the vacancy's consultant drafting (and spending AI calls).
  test "an HR Admin who is not the consultant cannot draft, and the AI is not called" do
    sign_in_as staff_user("hr_pic")
    client = assert_no_difference(-> { BriefSuggestion.count }) { draft! }
    assert_equal 0, client.calls
    refute_match(/case_saran=/, response.location.to_s)
  end

  # Catches: the download reading a proposal of another vacancy (IDOR by URL id).
  test "the draft download refuses another vacancy's proposal id" do
    sign_in_as @consultant
    draft!
    case_id, = ids_from(response.location)
    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    assert_equal 404, status_of { get staff_job_test_case_ai_case_file_path(other, case_id) }
  end

  # Catches: a proposal id that is not a case file (e.g. the case study text proposal) crashing the
  # download with a 500 instead of a clean refusal.
  test "the draft download of a non-case proposal id is refused cleanly, not a 500" do
    sign_in_as @consultant
    draft!
    _, saran = ids_from(response.location)
    status = status_of { get staff_job_test_case_ai_case_file_path(@job, saran) }
    assert_includes [404, 422, 302], status, "got #{status} (#{@raised&.class}: #{@raised&.message})"
  end

  # Catches: Save attaching another vacancy's drafted file through a forged case_saran.
  test "Save with another vacancy's case_saran saves nothing" do
    sign_in_as @consultant
    other = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    other.update!(consultant: @consultant)
    @job, mine = other, @job
    draft!
    foreign_id, = ids_from(response.location)
    @job = mine
    params = case_version_params(@job).except(:case_file)
    assert_no_difference -> { @job.test_cases.count } do
      assert_equal 404, status_of { post staff_job_test_cases_path(@job), params: { test_case: params, case_saran: foreign_id } }
    end
  end

  # Catches: Save with a non-case proposal id as case_saran crashing (500) instead of refusing.
  test "Save with a non-case proposal as case_saran is refused cleanly, not a 500" do
    sign_in_as @consultant
    draft!
    _, saran = ids_from(response.location)
    params = case_version_params(@job).except(:case_file)
    status = assert_no_difference(-> { @job.test_cases.count }) do
      status_of { post staff_job_test_cases_path(@job), params: { test_case: params, case_saran: saran } }
    end
    assert_includes [404, 422, 302], status, "got #{status} (#{@raised&.class}: #{@raised&.message})"
  end

  # Catches: the drafted file overriding a file the HR Admin chose (upload must win).
  test "Save with both an upload and case_saran stores the uploaded file" do
    sign_in_as @consultant
    draft!
    case_id, = ids_from(response.location)
    mine = xlsx_bytes([["Code", "Qty"], ["MINE-7781", 3]])
    params = case_version_params(@job, file: upload(mine, "mine.xlsx"))
    post staff_job_test_cases_path(@job), params: { test_case: params, case_saran: case_id }
    assert_redirected_to staff_job_test_case_step_path(@job)
    stored = @job.test_cases.reload.last.case_file.download
    assert_equal Digest::SHA256.hexdigest(mine), Digest::SHA256.hexdigest(stored), "the uploaded bytes are stored unchanged"
  end
end
