require "test_helper"

# AI_PROVIDER=gemini: request shape, reading the answer, and the same failure policy as
# every provider (§4.3). Gemini is stubbed at the HTTP boundary with WebMock.
class Screening::GeminiClientTest < ActiveSupport::TestCase
  STUDIO_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent".freeze
  VERTEX_URL = "https://aiplatform.googleapis.com/v1/projects/glassbox-uji/locations/global/publishers/google/models/gemini-3.8-flash:generateContent".freeze
  ANSWER = { "criteria" => [], "protected_attribute_seen" => false, "protected_attribute_categories" => [] }.freeze

  def gemini_env(**extra, &)
    with_env({ "AI_PROVIDER" => "gemini", "AI_MODEL" => nil, "AI_API_KEY" => "uji-gemini-key",
               "GOOGLE_SERVICE_ACCOUNT_JSON" => nil }.merge(extra), &)
  end

  def gemini_reply(text: ANSWER.to_json, finish: "STOP", **extra)
    { candidates: [{ content: { parts: [{ text: "pikiran", thought: true }, { text: }] }, finishReason: finish }],
      usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 40 }, modelVersion: "gemini-3.8-flash-001" }.merge(extra)
  end

  def judge_sample = Screening::Config.client.judge(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: Screening::Sample.rubric.payload)

  test "the provider setting picks the Gemini client and its default model" do
    gemini_env do
      assert_equal Screening::GeminiClient, Screening::Config.client_class
      assert_equal "gemini-3.8-flash", Screening::Config.model
      assert Screening::Config.enabled?
      assert_equal "ENV AI_API_KEY", Screening::Config.key_source
    end
    gemini_env("AI_API_KEY" => nil) { refute Screening::Config.enabled? }
  end

  test "a misspelled provider stops the boot with the accepted values" do
    error = assert_raises(Glassbox::Settings::Invalid) { Glassbox::Settings.validate!("TENANCY" => "single", "AI_PROVIDER" => "antropic") }
    assert_match(/AI_PROVIDER="antropic" is invalid; expected gemini/, error.message)
  end

  test "request: shared system prompt and schema, the user text byte for byte, key in a header" do
    sent = nil
    stub_request(:post, STUDIO_URL).with { |req| sent = req }.to_return(json_response(gemini_reply))
    reply = gemini_env { judge_sample }

    body = JSON.parse(sent.body)
    assert_equal "uji-gemini-key", sent.headers["X-Goog-Api-Key"]
    assert_equal Screening::AiClient::SYSTEM_PROMPT, body.dig("systemInstruction", "parts", 0, "text")
    assert_equal Screening::AiClient.user_content(Screening::Sample.redacted_cv, Screening::Sample.rubric.payload),
                 body.dig("contents", 0, "parts", 0, "text")
    assert_equal JSON.parse(Screening::AiClient::SCHEMA.to_json), body.dig("generationConfig", "responseJsonSchema")
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")

    # Thought parts are not part of the answer; the model that answered is stored.
    assert_equal ANSWER.to_json, reply.text
    assert_equal ["gemini-3.8-flash-001", 120, 40], [reply.model, reply.input_tokens, reply.output_tokens]
  end

  test "without an API key, Gemini goes through Vertex AI with the service account" do
    stub_google_token!
    sent = nil
    stub_request(:post, VERTEX_URL).with { |req| sent = req }.to_return(json_response(gemini_reply))
    gemini_env("AI_API_KEY" => nil, "GOOGLE_SERVICE_ACCOUNT_JSON" => fake_service_account_json) { judge_sample }
    assert_equal "Bearer uji-token", sent.headers["Authorization"]
  end

  test "a Vertex AI express-mode key goes to Vertex AI with the key in a header" do
    sent = nil
    stub_request(:post, VERTEX_URL).with { |req| sent = req }.to_return(json_response(gemini_reply))
    gemini_env("AI_API_KEY_ENDPOINT" => "vertex", "GOOGLE_CLOUD_PROJECT" => "glassbox-uji") do
      judge_sample
      assert_equal "ENV AI_API_KEY, Vertex AI express mode", Screening::Config.key_source
    end
    assert_equal "uji-gemini-key", sent.headers["X-Goog-Api-Key"]
    assert_nil sent.headers["Authorization"]

    # Without a project, express mode lets Google pick the location.
    express = "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash:generateContent"
    stub_request(:post, express).to_return(json_response(gemini_reply))
    gemini_env("AI_API_KEY_ENDPOINT" => "vertex", "GOOGLE_CLOUD_PROJECT" => nil) { judge_sample }
    assert_requested :post, express
  end

  test "failure policy: 429/5xx retried, other 4xx and refusals final, cut-off answers malformed" do
    cases = {
      json_response({}, status: 429) => [Screening::Errors::Transient, "HTTP 429"],
      json_response({}, status: 503) => [Screening::Errors::Transient, "HTTP 503"],
      json_response({}, status: 400) => [Screening::Errors::Permanent, "HTTP 400"],
      json_response(gemini_reply(finish: "SAFETY")) => [Screening::Errors::Permanent, "safety"],
      json_response({ promptFeedback: { blockReason: "PROHIBITED_CONTENT" } }) => [Screening::Errors::Permanent, "prohibited_content"],
      json_response(gemini_reply(finish: "MAX_TOKENS")) => [Screening::Errors::Malformed, "answer cut off (max_tokens)"],
      json_response(gemini_reply(text: " ")) => [Screening::Errors::Malformed, "empty answer"],
      { status: 200, body: "<html>proxy</html>" } => [Screening::Errors::Malformed, "the answer is not an AI message"]
    }
    cases.each do |response, (error_class, detail)|
      stub_request(:post, STUDIO_URL).to_return(response)
      error = assert_raises(error_class) { gemini_env { judge_sample } }
      assert_equal detail, error.detail
    end
  end

  test "a released text that changed is refused before anything is sent (D51 B)" do
    gemini_env do
      assert_raises(Screening::Errors::ReleaseMismatch) do
        Screening::Config.client.judge_released(payload: "teks", sha256: Digest::SHA256.hexdigest("teks lain"))
      end
    end
    assert_not_requested :post, STUDIO_URL
  end
end
