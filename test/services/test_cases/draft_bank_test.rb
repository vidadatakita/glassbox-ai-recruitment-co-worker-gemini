require "test_helper"

# TestCases::DraftBank: the AI proposes bank questions from the saved brief; Ruby keeps only rows
# that fit (a listed activity or competency, 2 to 6 distinct options with one right answer, three
# anchors for a written answer, no protected attribute). Nothing enters the bank here.
class TestCases::DraftBankTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:text, :seen, :task) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 5, output_tokens: 7)
    end
  end

  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
  end

  def with_ai(client)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, ->(task, job:) { client.task = task; client }) { yield }
    end
  end

  def row(**over)
    { section: "technical", activity: 1, competency: 0, kind: "multiple_choice", prompt: "What is 2 + 2?",
      options: %w[3 4 5 6], correct: 2, anchor_1: "", anchor_3: "", anchor_5: "" }.merge(over)
  end

  test "keeps usable rows, maps numbers to brief ids, drops and counts the rest, and changes no bank" do
    rows = [
      row,
      row(section: "role", activity: 0, competency: 1, kind: "written", options: [], correct: 0, anchor_1: "a", anchor_3: "b", anchor_5: "c"),
      row(activity: 0),                                   # 0 must not wrap to the last activity
      row(activity: 99),                                  # not in the list
      row(options: %w[same Same]),                        # options not distinct
      row(correct: 5),                                    # correct out of range
      row(prompt: "Only applicants under 25 years old"),  # protected attribute
      row(section: "role", activity: 0, competency: 1, kind: "written", options: [], correct: 0, anchor_1: "a", anchor_3: "", anchor_5: "c")
    ]
    client = FakeClient.new({ questions: rows }.to_json)
    result = with_ai(client) { TestCases::DraftBank.call(job: @job, actor: @admin) }
    assert result.ok?, result.error
    kept = result.suggestion.payload.dig("bank", "questions")
    assert_equal 2, kept.size
    assert_equal 6, result.suggestion.payload.dig("bank", "dropped")
    assert_equal [@job.activities.first.id.to_s, "1"], [kept.first["link_id"], kept.first["correct"]]
    assert_equal @job.competencies.first.id.to_s, kept.last["link_id"]
    assert_equal :test_bank, client.task
    assert_includes client.seen, "Write 10 technical questions and 6 role questions."
    assert_nil QuestionBank.latest_for(@job)
  end

  test "refuses without activities or competencies, and with AI off" do
    Screening::Config.stub(:enabled?, false) { refute TestCases::DraftBank.call(job: @job, actor: @admin).ok? }
    Competency.where(job_id: @job.id).delete_all
    result = with_ai(FakeClient.new("{}")) { TestCases::DraftBank.call(job: @job.reload, actor: @admin) }
    assert_match(/competencies in step 4/, result.error)
  end
end
