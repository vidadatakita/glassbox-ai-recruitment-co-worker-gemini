require "test_helper"

# "Write with AI" in the bank's Add a question form (17 Oct 2026): one question for the chosen section,
# type and brief row, returned as form fields (JSON) or prefilled on reload; nothing saved.
class WriteQuestionWithAiTest < ActionDispatch::IntegrationTest
  FakeClient = Struct.new(:reply, :seen) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "uji-model", text: reply.to_json, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @activity = @job.activities.first
    sign_in_as staff_user("hr_pic")
  end

  def with_ai(client, &) = Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, ->(*, **) { client }, &) }

  def ask(kind: "multiple_choice", link: "a:#{@activity.id}", section: "technical", format: :json)
    post staff_job_question_bank_questions_path(@job, format:), params: { ai: "1", bank: { section:, kind:, link_id: link } }
  end

  test "multiple choice: fields keyed by input name, the blank option does not move the key, nothing saved" do
    client = FakeClient.new({ prompt: "What is 12 x 45?", options: ["", "540", "560", "450", "500"], correct: 2, anchor_1: "", anchor_3: "", anchor_5: "" })
    with_ai(client) { assert_no_difference(-> { BankQuestion.count }) { ask } }
    assert_response :success
    body = response.parsed_body
    assert body["ok"]
    assert_equal "What is 12 x 45?", body["fields"]["bank[prompt]"]
    assert_equal "540", body["fields"]["bank[options][0]"]
    assert_equal "0", body["fields"]["bank[correct]"], "correct counts the options as sent (2nd = 540)"
    assert_includes client.seen, @activity.description
    assert_nil QuestionBank.latest_for(@job)
  end

  test "written: anchors filled; a protected attribute or missing anchors is refused with a sentence" do
    ok = FakeClient.new({ prompt: "Describe how you check a delivery.", options: [], correct: 0, anchor_1: "a", anchor_3: "b", anchor_5: "c" })
    with_ai(ok) { ask(kind: "written") }
    assert_equal "c", response.parsed_body["fields"]["bank[anchor_5]"]
    bad = FakeClient.new({ prompt: "Are you married?", options: [], correct: 0, anchor_1: "a", anchor_3: "b", anchor_5: "c" })
    with_ai(bad) { ask(kind: "written") }
    assert_response :unprocessable_content
    refute response.parsed_body["ok"]
    assert_match(/protected attribute/, response.parsed_body["message"])
  end

  test "a link from the other section is refused before the AI is called" do
    client = FakeClient.new({})
    with_ai(client) { ask(section: "role", link: "a:#{@activity.id}") }
    assert_response :unprocessable_content
    assert_nil client.seen
  end

  test "without JavaScript the page reloads with the form filled; an HR Manager is refused" do
    client = FakeClient.new({ prompt: "Which total is right?", options: %w[10 20], correct: 1, anchor_1: "", anchor_3: "", anchor_5: "" })
    with_ai(client) { ask(format: :html) }
    assert_response :success
    assert_select "textarea[name='bank[prompt]']", text: "Which total is right?"
    assert_select "input[name='bank[correct]'][value='0'][checked]"
    sign_in_as staff_user("reviewer")
    with_ai(client) { ask }
    assert_response :unprocessable_content
  end
end
