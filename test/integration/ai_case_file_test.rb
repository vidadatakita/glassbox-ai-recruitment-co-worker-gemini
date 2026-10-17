require "test_helper"

# AI co-worker for the uploaded case (slice D, 17 Oct 2026): one press drafts the case study text and
# the case file; the file holds only Instructions and Data (no answer key); Save attaches it through the
# same inspection as an upload; nothing is saved before Save.
class AiCaseFileTest < ActionDispatch::IntegrationTest
  FakeClient = Struct.new(:calls) do
    def generate(system:, schema:, content:)
      self.calls = (calls || 0) + 1
      text = if schema.dig(:properties, :planted)
               { title: "Purchase journal, October 2026", columns: %w[Date Supplier Qty Price Total],
                 rows: (1..8).map { |i| ["2026-10-0#{i}", "PT Contoh #{i}", "2", "1000", i == 3 ? "2500" : "2000"] },
                 planted: [{ row: 3, activity: 1, what: "Total is not Qty x Price", correct: "2000" }] }
             else
               { instructions: "Check the purchase journal in the case file and correct every wrong total.", time_limit_minutes: 30,
                 answer_types: ["xlsx"], criteria: [{ activity: 1, name: "Finds wrong totals", weight: 100, anchor_1: "none", anchor_3: "some", anchor_5: "all, row 3 = 2000" }] }
             end
      Screening::AiClient::Reply.new(model: "uji-model", text: text.to_json, input_tokens: 5, output_tokens: 7)
    end
  end

  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @job.update!(consultant: staff_user("consultant"))
  end

  def with_ai(&) = Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, ->(*, **) { FakeClient.new }, &) }

  test "drafts text and file, shows the answer key to staff only, and Save attaches the drafted file" do
    sign_in_as staff_user("consultant")
    with_ai do
      assert_no_difference -> { @job.test_cases.count } do
        post staff_job_test_case_ai_case_path(@job)
      end
    end
    location = response.location
    assert_match(/case_saran=/, location)
    get location
    assert_response :success
    assert_includes response.body, "Answer key (staff only"
    assert_includes response.body, "Total is not Qty x Price"
    proposal_id = location[/case_saran=(\d+)/, 1]
    saran = location[/saran=(\d+)/, 1]

    get staff_job_test_case_ai_case_file_path(@job, proposal_id, saran:)
    assert_response :success
    text = TechnicalTests::AnswerText.allocate.send(:xlsx, response.body)
    assert_includes text, "PT Contoh 3"
    refute_includes text, "Total is not Qty x Price", "the answer key never goes into the applicant's file"

    params = case_version_params(@job).except(:case_file).merge(instructions: "Check the purchase journal.")
    post staff_job_test_cases_path(@job), params: { test_case: params, case_saran: proposal_id }
    assert_redirected_to staff_job_test_case_step_path(@job)
    version = @job.test_cases.reload.last
    assert version.case_file.attached?
    assert_equal "xlsx", version.case_file_kind
  end

  test "an HR Manager cannot draft the case" do
    sign_in_as staff_user("reviewer")
    with_ai { post staff_job_test_case_ai_case_path(@job) }
    refute_match(/case_saran=/, response.location.to_s)
  end
end
