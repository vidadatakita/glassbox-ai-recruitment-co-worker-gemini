require "test_helper"
require_relative "bank_engine_helpers"

# Independent test pass, competency bank slice A: the AI proposal (TestCases::DraftBank) keeps only rows that
# fit, keeps the right answer on the option the model meant, never crashes on a bad or absent
# provider, and accepting a proposal behaves as its comment says.
class DraftBankEngineTest < ActiveSupport::TestCase
  include BankEngineHelpers

  StubClient = Struct.new(:reply_text, :error) do
    def generate(system:, schema:, content:)
      raise error if error

      Screening::AiClient::Reply.new(model: "uji-model", text: reply_text, input_tokens: 3, output_tokens: 4)
    end
  end

  setup { bank_setup! }

  def with_client(client, &block)
    Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, ->(_task, job:) { client }, &block) }
  end

  def draft(rows) = with_client(StubClient.new(JSON.generate(questions: rows))) { TestCases::DraftBank.call(job: @job, actor: @admin) }

  def mc_row(**over)
    { section: "technical", activity: 1, competency: 0, kind: "multiple_choice", prompt: "Which invoice total is right?",
      options: %w[Rp100 Rp200 Rp300 Rp400], correct: 2, anchor_1: "", anchor_3: "", anchor_5: "" }.merge(over)
  end

  # The model numbers options 1-4 as it wrote them. A blank option it left in the list is dropped;
  # the right answer must stay on the text the model marked, not slide to its neighbour.
  test "a blank option in the AI reply does not move the correct answer to another option" do
    result = draft([mc_row(options: ["", "Rp200", "Rp300", "Rp400"], correct: 2)])
    assert result.ok?, result.error
    row = result.suggestion.payload.dig("bank", "questions").first
    assert_equal "Rp200", row["options"][row["correct"]], "the model marked option 2 (Rp200)"
  end

  test "control: without blank options the 1-based answer maps to its option" do
    row = draft([mc_row(correct: 3)]).suggestion.payload.dig("bank", "questions").first
    assert_equal "Rp300", row["options"][row["correct"]]
  end

  test "rows with a protected attribute, an unlisted number or an out-of-range answer are dropped and counted" do
    rows = [mc_row(prompt: "Is the applicant married?"), mc_row(activity: 0), mc_row(activity: 99), mc_row(correct: 0),
            mc_row(correct: 5), mc_row(section: "role", activity: 0, competency: 1, kind: "written", options: [], correct: 0,
                                       anchor_1: "a", anchor_3: "", anchor_5: "c"),
            mc_row(prompt: "Control row")]
    bank = draft(rows).suggestion.payload["bank"]
    assert_equal ["Control row"], bank["questions"].map { |r| r["prompt"] }
    assert_equal 6, bank["dropped"]
    assert_nil QuestionBank.latest_for(@job), "drafting never writes the bank"
  end

  test "AI off, a busy provider and an unreadable reply each give a message and store nothing" do
    off = TestCases::DraftBank.call(job: @job, actor: @admin)
    assert_match(/AI drafting is off/, off.error) unless Screening::Config.enabled?
    busy = with_client(StubClient.new(nil, Screening::Errors::Transient.new("api_error", "HTTP 503"))) do
      TestCases::DraftBank.call(job: @job, actor: @admin)
    end
    assert_match(/busy or unreachable/, busy.error)
    garbled = with_client(StubClient.new("not json {")) { TestCases::DraftBank.call(job: @job, actor: @admin) }
    assert_match(/could not be read/, garbled.error)
    assert_equal 0, BriefSuggestion.where(job: @job).count
  end

  # SaveBank#apply_accept_ai (comment revised 17 Oct): all or nothing. If one ticked row no longer fits
  # the brief, the whole batch is refused with the reason and nothing is added. This checks that sentence.
  test "accepting a proposal with one orphaned row refuses the whole batch and leaves the bank unchanged" do
    second = @job.activities.second || flunk("the factory brief needs two activities")
    assert save_bank("add", mc_params(prompt: "Already in the draft")).ok?
    bank = QuestionBank.latest_for(@job)
    payload = { "bank" => { "questions" => [
      { "section" => "technical", "kind" => "multiple_choice", "link_id" => second.id.to_s, "prompt" => "Orphaned later",
        "options" => { "0" => "x", "1" => "y" }, "correct" => "0" },
      { "section" => "technical", "kind" => "multiple_choice", "link_id" => @activity.id.to_s, "prompt" => "Still fits",
        "options" => { "0" => "x", "1" => "y" }, "correct" => "1" }
    ] } }
    suggestion = BriefSuggestion.create!(job: @job, actor: @admin, model_id: "m", prompt_version: "p", payload:, created_at: Time.current)
    second.destroy!
    digest = bank.content_digest
    audits = JobBriefChange.where(job: @job, step: "5").count

    result = save_bank("accept_ai", { picks: %w[0 1] }, suggestion:)
    refute result.ok?
    assert_equal ["Proposed question: that activity is not in this vacancy's brief."], result.errors
    assert_equal ["Already in the draft"], bank.questions.reload.map(&:prompt), "nothing is added, not even the row that fits"
    assert_equal digest, bank.reload.content_digest
    assert_equal [1, audits], [QuestionBank.where(job: @job).count, JobBriefChange.where(job: @job, step: "5").count]

    # Control: ticking only the row that still fits adds it.
    assert save_bank("accept_ai", { picks: %w[1] }, suggestion:).ok?
    assert_equal ["Already in the draft", "Still fits"], bank.questions.reload.map(&:prompt)
  end
end
