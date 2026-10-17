require "test_helper"

# AI Builder Cup step 05: the reviewer may ask the AI for a proposed rating per criterion. The text
# is read and shown first, sent only as previewed (digest), mapped to criteria, and only fills the
# form: the score stays the reviewer's.
class TechnicalTests::AiScoreTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  FakeClient = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 5, output_tokens: 7)
    end
  end

  setup do
    @job = technical_test_job
    @application, = applicant!(@job, name: "Dewi Lestari")
  end

  def with_ai(client, &) = Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, client, &) }

  test "an xlsx answer is read cell by cell; the candidate's name is redacted" do
    attempt = travel_to(Time.current) do
      TechnicalTests::Start.call(application: @application)
      TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file(xlsx_bytes([["Kode", "Koreksi"], ["BRG-01", "selisih 12, dicek Dewi Lestari"]])))
    end
    text = TechnicalTests::AnswerText.call(attempt).text
    assert_includes text, "BRG-01"
    assert_includes text, "selisih 12"
    refute_includes text, "Dewi Lestari"
  end

  test "the AI's proposal is stored per criterion; ratings outside 1-5 or unknown criteria are left out" do
    attempt = answered!(@application)
    criteria = attempt.test_case.criteria.to_a
    answer = { "summary" => "Jawaban cukup lengkap.", "criteria" => [
      { "criterion" => 1, "rating" => 4, "reason" => "Selisih ditemukan.", "quote" => "BRG-01" },
      { "criterion" => 2, "rating" => 9, "reason" => "x", "quote" => "" },
      { "criterion" => 7, "rating" => 3, "reason" => "x", "quote" => "" }
    ] }
    client = FakeClient.new(answer.to_json)
    seen = TechnicalTests::AiScore.digest(TechnicalTests::AnswerText.call(attempt).text)
    suggestion = with_ai(client) { TechnicalTests::AiScore.call(attempt:, reviewer: reviewer, seen_sha256: seen) }

    assert_equal [{ "criterion_id" => criteria.first.id, "rating" => 4, "reason" => "Selisih ditemukan.", "quote" => "BRG-01", "verified" => true }], suggestion.criteria
    assert_equal seen, suggestion.sent_sha256
    assert_includes client.seen, "<answer>"
    assert_includes client.seen, "1. #{criteria.first.name}"
    assert_empty attempt.reload.review.to_a, "a proposal is never a score"
  end

  test "every proposed quote is checked verbatim against the answer: an invented quote and an unquoted high rating are unverified" do
    attempt = answered!(@application)
    criteria = attempt.test_case.criteria.to_a
    assert_operator criteria.size, :>=, 2, "control: the test case has two criteria to rate"
    answer = { "criteria" => [
      { "criterion" => 1, "quote" => "BRG-02 corrected by 15", "reason" => "Invented.", "rating" => 5 },
      { "criterion" => 2, "quote" => "", "reason" => "Nothing quoted.", "rating" => 4 }
    ], "summary" => "x" }
    seen = TechnicalTests::AiScore.digest(TechnicalTests::AnswerText.call(attempt).text)
    rows = with_ai(FakeClient.new(answer.to_json)) { TechnicalTests::AiScore.call(attempt:, reviewer: reviewer, seen_sha256: seen) }.criteria
    assert_equal [false, false], rows.map { |r| r["verified"] }, "a quote not in the answer, and a rating above 1 without a quote, are not evidence"

    answer["criteria"] = [{ "criterion" => 1, "quote" => "BRG-01", "reason" => "Found.", "rating" => 3 },
                          { "criterion" => 2, "quote" => "", "reason" => "Not addressed.", "rating" => 1 }]
    rows = with_ai(FakeClient.new(answer.to_json)) { TechnicalTests::AiScore.call(attempt:, reviewer: reviewer, seen_sha256: seen) }.criteria
    assert_equal [true, true], rows.map { |r| r["verified"] }, "control: a verbatim quote, and a 1 with nothing to quote, stand"
  end

  test "refused: text changed since the preview, the job's consultant, the AI switched off" do
    attempt = answered!(@application)
    client = FakeClient.new("{}")
    error = assert_raises(TechnicalTests::AiScore::Refused) { with_ai(client) { TechnicalTests::AiScore.call(attempt:, reviewer: reviewer, seen_sha256: "lain") } }
    assert_match(/changed since you checked it/, error.message)
    assert_nil client.seen, "nothing was sent"

    @job.update!(consultant: (consultant = staff_user("reviewer", email: "konsultan-juga@uji.example")))
    error = assert_raises(TechnicalTests::AiScore::Refused) { with_ai(client) { TechnicalTests::AiScore.call(attempt: attempt.reload, reviewer: consultant, seen_sha256: "x") } }
    assert_match(/not the consultant/, error.message)

    Screening::Config.stub(:enabled?, false) do
      assert_match(/is off/, assert_raises(TechnicalTests::AiScore::Refused) { TechnicalTests::AiScore.call(attempt:, reviewer: reviewer, seen_sha256: "x") }.message)
    end
  end

  test "a GitHub repository is read through the GitHub API on its fixed hosts; other hosts are scored by hand" do
    params = case_version_params(@job).merge(answer_types: %w[repo_link], answer_types_submitted: "1", new_version_reason: "Tes programmer")
    version = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params:).test_case
    TestCases::Approve.call(test_case: version, actor: staff_user("hr_pic"))
    TechnicalTests::Start.call(application: @application)
    attempt = TechnicalTests::SubmitAnswer.call(application: @application, url: "https://github.com/dewi/tes-api/tree/main")

    stub_request(:get, "https://api.github.com/repos/dewi/tes-api").to_return(body: { default_branch: "main" }.to_json)
    stub_request(:get, "https://api.github.com/repos/dewi/tes-api/git/trees/main?recursive=1").to_return(body: { tree: [
      { "type" => "blob", "path" => "src/app.js", "size" => 40 },
      { "type" => "blob", "path" => "node_modules/x/index.js", "size" => 10 },
      { "type" => "blob", "path" => "logo.png", "size" => 10 }
    ] }.to_json)
    stub_request(:get, "https://raw.githubusercontent.com/dewi/tes-api/main/src/app.js").to_return(body: "app.get('/stok', handler)")

    result = TechnicalTests::AnswerText.call(attempt)
    assert result.ok?, result.problem
    assert_includes result.text, "=== src/app.js ===\napp.get('/stok', handler)"
    refute_includes result.text, "node_modules"

    gitlab = TestAttempt.new(answered_at: Time.current, answer_kind: "repo_link", answer_url: "https://gitlab.com/dewi/tes-api")
    assert_match(/can only read GitHub repositories/, TechnicalTests::AnswerText.call(gitlab).problem)
  end
end
