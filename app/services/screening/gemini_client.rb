module Screening
  # The Google Gemini provider (AI_PROVIDER=gemini). Plain REST generateContent, no SDK.
  #
  # Two ways in, picked by which credentials exist:
  # - AI_API_KEY (or credentials ai.api_key): the Gemini API (AI Studio). Easiest locally. With
  #   AI_API_KEY_ENDPOINT=vertex the key is a Vertex AI express-mode key instead (Google Cloud
  #   console), sent to Vertex AI in GOOGLE_CLOUD_PROJECT (optional) at GOOGLE_CLOUD_LOCATION.
  # - otherwise the service account of the Google integrations (GOOGLE_SERVICE_ACCOUNT_JSON, see
  #   GoogleIntegration::Config): Vertex AI in that key's project, location GOOGLE_CLOUD_LOCATION
  #   (default "global"). This is what bin/gcp deploys; the account has roles/aiplatform.user.
  #
  # Request shape: the same system prompt and JSON schema as every provider (AiClient), answer as
  # application/json under responseJsonSchema. Thinking is the model's default unless AI_THINKING
  # (or the task's own setting) names a level; its parts are never read. No retries here: the
  # retry policy is ScreenParticipationJob's (§4.3).
  #
  # Errors carry only a kind and a short detail such as "HTTP 429" or a block reason, never the
  # request or response body (ONP-19).
  class GeminiClient < AiClient
    SCOPE = "https://www.googleapis.com/auth/cloud-platform".freeze
    # finishReason values that mean the answer is complete. MAX_TOKENS is malformed (cut off);
    # anything else (SAFETY, RECITATION, BLOCKLIST, PROHIBITED_CONTENT, SPII, ...) is a refusal.
    COMPLETE = [nil, "STOP"].freeze

    def self.configured? = Config.api_key.present? || GoogleIntegration::Config.service_account_present?

    def self.credential_source
      return "#{Config.api_key_source}, Vertex AI express mode" if Config.api_key.present? && ENV["AI_API_KEY_ENDPOINT"].to_s.strip == "vertex"
      return Config.api_key_source if Config.api_key.present?
      return "Vertex AI, service account (#{GoogleIntegration::Config.source(:service_account_json)})" if GoogleIntegration::Config.service_account_present?

      nil
    end

    def initialize(model: Config.model, thinking: Config.thinking)
      raise Errors::NotConfigured, "no Gemini credentials configured" unless self.class.configured?

      @model = model
      @thinking = thinking
      @api_key = Config.api_key
    end

    def count(content)
      body = studio? ? { generateContentRequest: { model: "models/#{@model}", **contents(content) } } : contents(content)
      post("countTokens", body).fetch("totalTokens")
    end

    private

    def call_api(content, system:, schema:)
      config = { responseMimeType: "application/json", responseJsonSchema: schema, maxOutputTokens: MAX_TOKENS }
      config[:thinkingConfig] = { thinkingLevel: @thinking } if @thinking
      body = contents(content, system:).merge(generationConfig: config)
      read(post("generateContent", body))
    end

    def contents(content, system: SYSTEM_PROMPT)
      { systemInstruction: { parts: [{ text: system }] }, contents: [{ role: "user", parts: [{ text: content }] }] }
    end

    def read(response)
      if (blocked = response.dig("promptFeedback", "blockReason"))
        raise Errors::Permanent.new("refusal", blocked.to_s.downcase)
      end

      candidate = response["candidates"]&.first
      raise Errors::Malformed.new("malformed", "the answer is not an AI message") unless candidate.is_a?(Hash)

      reason = candidate["finishReason"]
      raise Errors::Malformed.new("malformed", "answer cut off (max_tokens)") if reason == "MAX_TOKENS"
      raise Errors::Permanent.new("refusal", reason.to_s.downcase) unless COMPLETE.include?(reason)

      text = Array(candidate.dig("content", "parts")).reject { |part| part["thought"] }.map { |part| part["text"].to_s }.join
      raise Errors::Malformed.new("malformed", "empty answer") if text.strip.empty?

      usage = response["usageMetadata"] || {}
      Reply.new(model: response["modelVersion"].presence || @model, text:,
                input_tokens: usage["promptTokenCount"], output_tokens: usage["candidatesTokenCount"],
                thinking_tokens: usage["thoughtsTokenCount"])
    end

    def post(method, body)
      uri, headers = endpoint(method)
      post_json(uri, headers, body)
    end

    # The AI Studio endpoint: an API key that is not marked as a Vertex AI express-mode key.
    def studio? = @api_key.present? && ENV["AI_API_KEY_ENDPOINT"].to_s.strip != "vertex"

    def endpoint(method)
      if studio?
        [URI("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:#{method}"), { "x-goog-api-key" => @api_key }]
      elsif @api_key
        [vertex_uri(ENV["GOOGLE_CLOUD_PROJECT"].to_s.strip.presence, method), { "x-goog-api-key" => @api_key }]
      else
        key = GoogleIntegration::Config.service_account
        [vertex_uri(key["project_id"], method), { "Authorization" => "Bearer #{access_token(key)}" }]
      end
    end

    # Without a project (express mode only) Google picks the location; some models exist only at "global".
    def vertex_uri(project, method)
      return URI("https://aiplatform.googleapis.com/v1/publishers/google/models/#{@model}:#{method}") if project.nil?

      location = ENV["GOOGLE_CLOUD_LOCATION"].to_s.strip.presence || "global"
      host = location == "global" ? "aiplatform.googleapis.com" : "#{location}-aiplatform.googleapis.com"
      URI("https://#{host}/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{@model}:#{method}")
    end

    def access_token(key)
      require "googleauth"
      Google::Auth::ServiceAccountCredentials
        .make_creds(json_key_io: StringIO.new(JSON.generate(key)), scope: SCOPE)
        .fetch_access_token!.fetch("access_token")
    rescue Signet::AuthorizationError
      raise Errors::Permanent.new("rejected", "service account rejected by Google")
    rescue Signet::RemoteServerError, Signet::UnexpectedStatusError, Faraday::Error
      raise Errors::Transient.new("connection", "the Google token could not be fetched")
    end
  end
end
