require "test_helper"

# Screening standard item (FLOW §8.11, Appendix A): the 1/2/3 ratings are judged against written
# behavioural anchors, each backed by a verbatim quote, and the prompt version that carries them is
# stored on every result. The assertions read the SYSTEM PROMPT THE REAL CLIENT SENT (FakeGemini at
# the HTTP boundary), not the constant, so a prompt that is edited but not sent would be caught.
# Stated selection: this pins the anchor STRUCTURE (three anchored levels above "none", quote
# required above 0); the anchor wording is the team's to confirm, so only its labels are asserted.
# Mutant: delete the three "anchor" lines from Screening::AiClient::SYSTEM_PROMPT -> red.
class Screening::RubricAnchorsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
  end

  test "the system prompt sent to the model carries the three anchors on the existing 0-3 scale, and the result stores the prompt version" do
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    sent = request_system_text(@fake.parsed_bodies.sole)
    assert_includes sent, "0 = no evidence"
    assert_includes sent, "1 = anchor LOW"
    assert_includes sent, "2 = anchor MID"
    assert_includes sent, "3 = anchor HIGH"
    assert_includes sent, "Appendix A"
    assert_includes sent, "a rating you cannot quote is \"0\""
    # The scale did not move: the schema still accepts exactly 0-3 and met/not_met.
    assert_equal %w[met not_met 0 1 2 3], request_schema(@fake.parsed_bodies.sole).dig("properties", "criteria", "items", "properties", "judgement", "enum")
    result = @participation.screening_results.sole
    assert_equal "s1-2026-10-17.5", result.prompt_version
    assert_equal "s1-2026-10-17.5", @participation.score_entries.sole.prompt_version
  end

  # Prompt .4 (16 Oct agreement check: 12 of 17 rating disagreements had the AI higher, because
  # "the tool or duty without the level is 2" rated a bare "Excel (data entry)" like pivot tables).
  # Mutant: put the old rule back, or drop the "named only" anchor -> red.
  test "the anchors rate what the CV shows: named only 1, concrete detail 2, the level asked 3; quotes come before the judgement" do
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    body = @fake.parsed_bodies.sole
    sent = request_system_text(body)
    assert_includes sent, "1 = anchor LOW, named only or related"
    assert_includes sent, "2 = anchor MID, concrete detail"
    assert_includes sent, "3 = anchor HIGH, as asked"
    assert_includes sent, "supervising a single outlet, branch or site, or coaching a single person"
    refute_includes sent, "the tool or duty without the level is \"2\""
    item = request_schema(body).dig("properties", "criteria", "items")
    assert_equal %w[id quotes judgement], item["properties"].keys, "key order is generation order: the evidence first"
    assert_equal({ "type" => "string" }, item.dig("properties", "quotes", "items"))
    assert_includes sent, "quotes holds one to three passages"
  end
end
