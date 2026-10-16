require "test_helper"

# Blueprint §5.1 row 2 "Screening on a protected attribute", asserted on the OUTGOING API REQUEST
# BODY: the Gemini API is stubbed at the HTTP boundary (ScreeningFactory::FakeGemini is the
# AiClient.http_override seam), so the body checked here is the one the real GeminiClient built.
class Screening::OutgoingRequestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
  end

  def screen_fixture_cv(criteria = nil)
    with_ai(@fake) do
      @fake.push(gemini_message(criteria || criteria_for(@job)))
      @participation = apply_with_cv!(@job)
      screen_and_release! # D51 B: a reviewer releases the held text first
    end
    assert_equal 1, @fake.requests.size, "exactly one API call"
    @fake.bodies.first
  end

  test "no protected value from the Indonesian fixture CV is in the outgoing request body" do
    body = screen_fixture_cv
    PROTECTED.each { |value| refute_includes body, value, "#{value.inspect} reached the Gemini API" }
    EVIDENCE.each { |value| assert_includes body, value, "evidence #{value.inspect} did not reach the model" }
    # Control: the same values ARE in the text the portal extracted, so the refutations can fail.
    extracted = @participation.job_application.reload.cv_text
    PROTECTED.each { |value| assert_includes extracted, value }
  end

  test "the rubric payload holds only the brief's requirements: id, tier, text, cv evidence" do
    body = JSON.parse(screen_fixture_cv)
    content = body.dig("contents", 0, "parts", 0, "text")
    rubric = JSON.parse(content[/<requirements>\n(.*)\n<\/requirements>/m, 1])
    expected = @job.requirements.map { |r| { "id" => "R#{r.id}", "tier" => r.tier, "requirement" => r.text, "cv_evidence" => r.cv_evidence } }
    assert_equal expected.sort_by { |r| r["id"] }, rubric.sort_by { |r| r["id"] }
    serialized = JSON.generate(body)
    [@job.title, @job.client_company.name, @job.salary_min.to_s, "weight"].reject(&:blank?).each do |leak|
      refute_includes serialized.sub(/"maxOutputTokens":\d+/, ""), leak, "#{leak.inspect} is not part of the rubric"
    end
  end

  test "request shape: configured model in the URL, key in the header, JSON answer under the shared schema" do
    body = JSON.parse(screen_fixture_cv)
    request = @fake.requests.first
    assert_match %r{/models/gemini-3\.8-pro:generateContent\z}, request[:url].to_s
    assert_equal FAKE_KEY, request[:headers]["x-goog-api-key"]
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    assert_equal JSON.parse(Screening::AiClient::SCHEMA.to_json), request_schema(body)
    assert_equal Screening::AiClient::SYSTEM_PROMPT, request_system_text(body)
  end

  test "a fabricated quote marks that criterion unverified and routes the CV to the reviewer" do
    key = rubric_keys(@job).find { |k| Requirement.find(k.delete("R")).tier == "sebaiknya" }
    screen_fixture_cv(criteria_for(@job, quotes: { key => "Supervisor gudang di PT Sentosa selama 10 tahun" }))
    result = @participation.screening_results.last
    assert_equal 1, result.unverified_count
    row = result.criteria.find { |c| c["key"] == key }
    refute row["verified"]
    item = Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == @participation.id }
    assert_equal "unverified", item.reason
  end

  test "every S1 ScoreEntry stores the model that answered and the prompt version" do
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job), model: "gemini-3.8-flash-001"))  # the fallback model answered
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    entry = @participation.score_entries.sole
    assert_equal "gemini-3.8-flash-001", entry.model_id
    assert_equal Screening::PROMPT_VERSION, entry.prompt_version
    assert_equal Screening::AI_ACTOR_ID, entry.entered_by_id
    assert_equal BigDecimal("100.0"), entry.value
  end

  test "the database refuses an AI-actor entry that does not name its model" do
    participation = apply_with_cv!(@job)
    participation.update!(attendance: "attended")
    refused_by_database do
      ScoreEntry.insert!({ participation_id: participation.id, value: 50, entered_by_id: 0, entered_at: Time.current })
    end
  end

  test "the runbook's token count and sample CV send no real person's data" do
    fake = FakeGemini.new({ totalTokens: 1834 })
    with_ai(fake) do
      tokens = Screening::GeminiClient.new.count_tokens(redacted_cv: Screening::Sample.redacted_cv,
                                                        rubric_payload: Screening::Sample.rubric.payload)
      assert_equal 1834, tokens
    end
    assert_match %r{:countTokens\z}, fake.requests.first[:url].to_s
    refute_includes fake.bodies.first, "Contoh Kandidat Fiktif"
    refute_includes fake.bodies.first, "01-01-1990"
  end

  test "without a key or a service account the client refuses to be built, so no request can be made" do
    with_env("AI_API_KEY" => nil, "GOOGLE_SERVICE_ACCOUNT_JSON" => nil) do
      assert_raises(Screening::Errors::NotConfigured) { Screening::GeminiClient.new }
    end
  end

  # ADR 0004, line 3: the model reports protected attributes by category; such a result goes to the
  # reviewer and only the category is logged.
  test "the schema requires the protected-attribute flag and the prompt says what it is for" do
    body = JSON.parse(screen_fixture_cv)
    schema = body.dig("generationConfig", "responseJsonSchema")
    assert_equal %w[criteria protected_attribute_seen protected_attribute_categories], schema["required"]
    assert_equal "boolean", schema.dig("properties", "protected_attribute_seen", "type")
    assert_equal Screening::AiClient::PROTECTED_CATEGORIES, schema.dig("properties", "protected_attribute_categories", "items", "enum")
    assert_includes body.dig("systemInstruction", "parts", 0, "text"), "must never influence any judgement"
    assert_includes body.dig("systemInstruction", "parts", 0, "text"), "protected_attribute_seen"
  end

  test "a result where the model saw a protected attribute is never decided automatically and logs the category only" do
    io = StringIO.new
    log = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(log)
    begin
      with_ai(@fake) do
        @fake.push(gemini_message(criteria_for(@job), protected: %w[religion]))
        @participation = apply_with_cv!(@job)
        screen_and_release!
      end
    ensure
      Rails.logger.stop_broadcasting_to(log)
    end
    result = @participation.screening_results.sole
    assert_equal %w[religion], result.protected_attribute_categories
    item = Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == @participation.id }
    assert_equal "protected_attribute", item.reason
    assert_includes io.string, "protected_attribute_seen categories=religion"
  end

  test "a missing flag is read as 'seen, other' (to the reviewer), never as a clean result" do
    criteria = criteria_for(@job)
    with_ai(@fake) do
      @fake.push(gemini_message(nil, text: JSON.generate({ criteria: })))
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    assert_equal %w[other], @participation.screening_results.sole.protected_attribute_categories
  end
end
