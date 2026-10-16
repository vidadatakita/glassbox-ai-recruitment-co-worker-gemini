require "test_helper"
require_relative "screening_engine_support"

# §5.1 row 2 "Rubric payload contains only the brief's requirements", and the request shape
# checked against the Gemini generateContent API (systemInstruction + one user turn, JSON answer
# under responseJsonSchema with additionalProperties false and no numeric/length constraints, the
# key in the x-goog-api-key header, no sampling parameters, no tools).
class EngineScreeningRequestShapeTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    @job.update!(salary_min: 4_750_000, salary_max: 5_350_000)
    # Another job of the same client with its own, distinctive requirements and screening.
    @other = screening_job
    @other.update!(title: "Kepala Gudang Distribusi")
    @other.requirements.create!(tier: "wajib", text: "Sertifikat K3 Umum", cv_evidence: "Sertifikat K3 disebut", position: 9)
  end

  def first_body
    _, fake = screen_text!(@job, FIXTURE_CV)
    @fake = fake
    JSON.parse(fake.bodies.first)
  end

  def rubric_from(body)
    content = body.dig("contents", 0, "parts", 0, "text")
    content = content.map { |b| b["text"] }.join if content.is_a?(Array)
    JSON.parse(content[%r{<requirements>\n(.*)\n</requirements>}m, 1])
  end

  test "the rubric payload is exactly this job's requirements: id, tier, text, cv evidence; nothing else" do
    body = first_body
    expected = @job.requirements.order(:id).map do |r|
      { "id" => "R#{r.id}", "tier" => r.tier, "requirement" => r.text, "cv_evidence" => r.cv_evidence }
    end
    assert_equal expected, rubric_from(body).sort_by { |r| r["id"].delete("R").to_i }
    whole = body_strings(@fake.bodies.first)
    refute_includes whole, "Sertifikat K3", "another job's requirement reached the request"
    refute_includes whole, "Kepala Gudang", "another job's title reached the request"
    knockout = @job.knockout_questions.pluck(:text)
    assert_operator knockout.size, :>, 0, "control: the job has knockout questions"
    knockout.each { |q| refute_includes whole, q, "knockout question #{q.inspect} reached the request" }
    application = @job.job_applications.sole
    assert application.knockout_answers.present?, "control: the application holds knockout answers" if application.respond_to?(:knockout_answers)
    ["4750000", "4.750.000", "5350000", "5.350.000", @job.title, @job.client_company.name].each do |leak|
      refute_includes whole, leak, "#{leak.inspect} is not part of the rubric"
    end
    weights = @job.requirements.where(tier: "sebaiknya").pluck(:weight)
    assert_equal [60, 40], weights.sort.reverse, "control: the job has weights to leak"
    refute(rubric_from(body).any? { |r| r.key?("weight") }, "weights are scored in Ruby, never sent")
  end

  test "request shape is one the Gemini generateContent API accepts: JSON answer under the shared schema, no sampling knobs" do
    body = first_body
    request = @fake.requests.first
    assert_match %r{/v1beta/models/gemini-3\.8-pro:generateContent\z}, request[:url].to_s, "the HIGH tier's model is in the URL"
    assert_equal FAKE_KEY, request[:headers]["x-goog-api-key"], "the key travels in the header, never in the URL or body"
    assert_equal "application/json", request[:headers]["Content-Type"]
    config = body.fetch("generationConfig")
    assert_equal "application/json", config["responseMimeType"]
    assert_kind_of Integer, config["maxOutputTokens"]
    assert_operator config["maxOutputTokens"], :<=, 16_000, "non-streaming request: keep the output cap at or under ~16000"
    assert_equal({ "thinkingLevel" => "high" }, config["thinkingConfig"], "the HIGH tier thinks at level high (FLOW §9)")
    %w[temperature topP topK candidateCount stopSequences tools toolConfig].each do |forbidden|
      refute body.key?(forbidden) || config.key?(forbidden), "#{forbidden} is not part of the screening request"
    end
    assert_equal "user", body.dig("contents", 0, "role")
    assert_equal 1, body["contents"].size, "one user turn, no model prefill"
    assert_equal 1, body.dig("contents", 0, "parts").size, "one text part: the user content"
    assert_equal Screening::AiClient::SYSTEM_PROMPT, request_system_text(body)
    schema = request_schema(body)
    objects = []
    walk = ->(node) { if node.is_a?(Hash) then objects << node if node["type"] == "object"; node.each_value { |v| walk.call(v) } elsif node.is_a?(Array) then node.each { |v| walk.call(v) } end }
    walk.call(schema)
    assert_operator objects.size, :>=, 2
    objects.each { |o| assert_equal false, o["additionalProperties"], "structured outputs need additionalProperties false on every object" }
    %w[minimum maximum multipleOf minLength maxLength minItems maxItems pattern].each do |k|
      refute_includes JSON.generate(schema), "\"#{k}\"", "#{k} is not supported by structured outputs"
    end
  end

  test "the runbook's token count uses the same contents without generation-only fields" do
    fake = FakeGemini.new({ totalTokens: 2000 })
    with_ai(fake) do
      Screening::GeminiClient.new.count_tokens(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: Screening::Sample.rubric.payload)
    end
    body = JSON.parse(fake.bodies.first)
    assert_match %r{/models/gemini-3\.8-pro:countTokens\z}, fake.requests.first[:url].to_s
    inner = body.fetch("generateContentRequest")
    assert_equal "models/gemini-3.8-pro", inner["model"]
    assert_equal Screening::AiClient::SYSTEM_PROMPT, request_system_text(inner)
    refute inner.key?("generationConfig"), "countTokens takes no generation config"
  end
end
