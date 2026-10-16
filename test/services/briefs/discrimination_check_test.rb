require "test_helper"

# Screening standard item (Appendix D structure): the discrimination test on every brief
# requirement, keep / replace / delete with a reason, rule pass first and final, AI pass for the
# proxies. Risks hunted: the AI talking a named attribute back into the brief ("keep" on an age
# line); a "replace" with no wording (nothing for the HR owner to accept); an answer for a
# requirement the brief does not have; the AI being off and the result looking complete.
# Mutant: swap the precedence `rule[key] || ai[key]` -> `ai[key] || rule[key]` in #call -> red.
class Briefs::DiscriminationCheckTest < ActiveSupport::TestCase
  include ScreeningFactory

  FakeClient = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      (self.seen ||= []) << [system, schema, content]
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = screening_job
    @age = @job.requirements.create!(tier: "sebaiknya", text: "Young and energetic, maximum age 25", cv_evidence: "Date of birth", weight: 0, position: 9)
    @native = @job.requirements.create!(tier: "nilai_tambah", text: "Native English speaker", cv_evidence: "Nationality", position: 9)
    @gender = @job.requirements.create!(tier: "nilai_tambah", text: "Female staff preferred for the front desk", cv_evidence: "Gender", position: 10)
  end

  def key(requirement) = "R#{requirement.id}"
  def with_ai(answer) = Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, FakeClient.new(answer.to_json)) { yield } }

  test "with the AI off: the rule pass marks a named attribute 'replace' and every other line says the AI did not run" do
    lines = Screening::Config.stub(:enabled?, false) { Briefs::DiscriminationCheck.call(@job) }
    assert_equal @job.requirements.count, lines.size
    age = lines.find { |l| l["id"] == key(@age) }
    assert_equal %w[replace rule], [age["verdict"], age["source"]]
    assert_match(/age limit/i, age["reason"])
    assert_equal %w[replace rule], lines.find { |l| l["id"] == key(@gender) }.values_at("verdict", "source")
    others = lines.reject { |l| [key(@age), key(@gender)].include?(l["id"]) }
    assert_equal lines.size - 2, others.size
    assert others.all? { |l| l["verdict"] == "keep" && l["source"] == "rule" && l["reason"] == Briefs::DiscriminationCheck::AI_DID_NOT_RUN }, others.inspect
    assert Briefs::DiscriminationCheck.open?(lines)
  end

  test "with the AI on: proxies get the AI's verdict and wording; a rule hit stays 'replace' even when the AI says keep" do
    answer = { "lines" => [
      { "id" => key(@native), "verdict" => "replace", "reason" => "Nationality is a proxy for ethnicity.", "replacement" => "Fluent English for client calls, tested in the interview" },
      { "id" => key(@age), "verdict" => "replace", "reason" => "Age proxy.", "replacement" => "Able to work rotating shifts" },
      { "id" => key(@gender), "verdict" => "keep", "reason" => "Fine.", "replacement" => "" },
      { "id" => "R999999", "verdict" => "delete", "reason" => "not a requirement of this brief", "replacement" => "" },
      { "id" => key(@job.requirements.first), "verdict" => "keep", "reason" => "Task-related and testable from the diploma.", "replacement" => "" }
    ] }
    lines = with_ai(answer) { Briefs::DiscriminationCheck.call(@job) }
    native = lines.find { |l| l["id"] == key(@native) }
    assert_equal ["replace", "ai", "Fluent English for client calls, tested in the interview"], [native["verdict"], native["source"], native["replacement"]]
    age = lines.find { |l| l["id"] == key(@age) }
    assert_equal %w[replace rule], [age["verdict"], age["source"]], "a rule hit keeps the rule's verdict and reason"
    assert_match(/age limit/i, age["reason"])
    refute_match(/Age proxy/, age["reason"])
    assert_equal "Able to work rotating shifts", age["replacement"], "the AI's neutral wording is still offered for the HR owner to accept"
    gender = lines.find { |l| l["id"] == key(@gender) }
    assert_equal ["replace", "rule", ""], gender.values_at("verdict", "source", "replacement"), "the AI must not talk a named attribute back into the brief"
    refute lines.any? { |l| l["id"] == "R999999" }
    first = lines.find { |l| l["id"] == key(@job.requirements.first) }
    assert_equal %w[keep ai], [first["verdict"], first["source"]]
    assert_equal @job.requirements.count, lines.size
  end

  test "a 'replace' with no wording, an unknown verdict, and a non-JSON answer each fall back to the rule pass" do
    answer = { "lines" => [{ "id" => key(@native), "verdict" => "replace", "reason" => "x", "replacement" => "  " },
                           { "id" => key(@job.requirements.first), "verdict" => "maybe", "reason" => "x", "replacement" => "" }] }
    lines = with_ai(answer) { Briefs::DiscriminationCheck.call(@job) }
    native = lines.find { |l| l["id"] == key(@native) }
    assert_equal ["keep", "rule", Briefs::DiscriminationCheck::AI_DID_NOT_RUN], [native["verdict"], native["source"], native["reason"]]
    assert_equal %w[keep rule], lines.find { |l| l["id"] == key(@job.requirements.first) }.values_at("verdict", "source")
    assert_equal %w[replace rule], lines.find { |l| l["id"] == key(@gender) }.values_at("verdict", "source")

    broken = Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, FakeClient.new("not json")) { Briefs::DiscriminationCheck.call(@job) } }
    assert_equal %w[replace rule], broken.find { |l| l["id"] == key(@age) }.values_at("verdict", "source")
    assert_equal @job.requirements.count, broken.size
  end

  test "the AI receives only the requirements (id, tier, text, cv_evidence) under the Appendix D system prompt, with the keep/replace/delete schema" do
    client = FakeClient.new({ "lines" => [] }.to_json)
    Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, client) { Briefs::DiscriminationCheck.call(@job) } }
    system, schema, content = client.seen.sole
    assert_equal Briefs::DiscriminationCheck::AI_SYSTEM, system
    assert_equal %w[keep replace delete], schema.dig(:properties, :lines, :items, :properties, :verdict, :enum)
    sent = JSON.parse(content)
    assert_equal @job.requirements.count, sent.size
    assert_equal %w[id tier requirement cv_evidence], sent.first.keys
    refute_match(/#{@job.title}|salary|Rp/i, content, "nothing about the vacancy but its requirements travels")
  end
end
