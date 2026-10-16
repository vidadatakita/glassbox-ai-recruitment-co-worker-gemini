module Screening
  # Whether the AI is switched on, with which provider and which model (D50).
  #
  # Every AI setting is an ENV value (.env):
  # - AI_PROVIDER  gemini, the only provider (Google Cloud AI Builder Cup 2026: Google products only)
  # - AI_API_KEY   the Gemini API key (Rails credentials ai.api_key wins over it); unset = Vertex AI
  #                with the service account of the Google integrations
  # - AI_MODEL     model id; default below
  # - AI_THINKING  low, medium or high; unset = the model's default
  # - AI_SCREENING_REVIEW  auto (default): the AI screens every CV as it arrives and people decide
  #                on the result; required: a reviewer releases each redacted CV before the AI
  #                sees it (D51 B). A CV whose redacted text still shows personal data, or holds
  #                instruction-like text, is held for a person in both modes (Screening::ReleaseGate).
  #                GlassBox Team, 2026-10-13: back to auto as the default (reverses the 2026-10-12 "1a" ruling).
  # Per tier, AI_MODEL_<TIER> and AI_THINKING_<TIER> override the two above (TIERS, TASK_TIERS), so a
  # judgement a person acts on runs on the strong model and drafting on a fast one. Same provider and
  # key for every task.
  # The key is set on the server and never appears in the repository, a screen, a log or a job
  # argument. Without it the AI is OFF: nothing is sent, nothing is scored, and the job page and
  # Antrean Kerja say "Screening AI belum aktif. Kunci API belum diatur."
  #
  # PROVIDERS is kept as a table on purpose: every caller goes through Config, so the provider
  # is one row here plus its name in the AI_PROVIDER values of the settings registry. Only Google's
  # Gemini is allowed in this project (competition rule); do not add another vendor.
  module Config
    PROVIDERS = {
      "gemini" => { client: "Screening::GeminiClient" }
    }.freeze

    # FLOW v2.1 §9 (team decision 16 Oct 2026): three model tiers. A tier is one Gemini model id and one
    # thinking level, set in configuration (AI_MODEL_<TIER>, AI_THINKING_<TIER>), never in code and
    # never by the AI; the values below are the defaults a plain install runs with. A task names its
    # tier in TASK_TIERS, so moving a task between tiers is one line here.
    TIERS = {
      high: { model_key: "AI_MODEL_HIGH", thinking_key: "AI_THINKING_HIGH", model: "gemini-3.8-pro", thinking: "high" },
      medium: { model_key: "AI_MODEL_MEDIUM", thinking_key: "AI_THINKING_MEDIUM", model: "gemini-3.8-flash", thinking: "medium" },
      low: { model_key: "AI_MODEL_LOW", thinking_key: "AI_THINKING_LOW", model: "gemini-3.5-flash-lite", thinking: "low" }
    }.freeze
    # HIGH: a judgement a person acts on. MEDIUM: structured drafting a person edits. LOW: short text
    # and simple classification. The fairness check runs on the screening tier or its comparison is void.
    TASK_TIERS = {
      screening: :high, test_scoring: :high, stage_advice: :high, salary: :high, fairness: :high,
      brief: :medium, discrimination_check: :medium, red_flags: :medium,
      ad: :low, ad_scan: :low, letter: :low, chat: :low, status_text: :low
    }.freeze
    # Rule 6: model ids are defaults, not facts. This is the allowlist the team confirmed in the Google
    # Cloud project (glassbox:ai:smoke TIER=high|medium|low at deploy; results in docs/BUILD-LOG.md). A
    # configured id outside it stops the boot (validate_models!), never a silent fallback. Confirmed
    # ids are appended here at deploy; the list is the record.
    KNOWN_MODELS = %w[gemini-3.8-pro gemini-3.8-flash gemini-3.5-flash-lite gemini-4-argon].freeze

    module_function

    def provider = ENV["AI_PROVIDER"].to_s.strip.presence || "gemini" # the AI Builder Cup build runs on Gemini
    def client_class = PROVIDERS.fetch(provider)[:client].constantize
    def tier(task) = TASK_TIERS.fetch(task.to_sym) { raise ArgumentError, "unknown AI task #{task.inspect}; add it to Screening::Config::TASK_TIERS" }
    # The client for one task, on the model and thinking its tier resolves to. job: a vacancy whose
    # portal has opened carries the mapping locked at that moment (rule 2); it wins over the environment
    # so a later configuration change never alters the results of an open vacancy.
    # Raises Errors::NotConfigured without credentials.
    def client(task = :screening, job: nil) = client_class.new(model: model(task, job:), thinking: thinking(task, job:)).tap { |c| c.task = task.to_sym }
    def enabled? = client_class.configured?
    def model(task = :screening, job: nil) = locked(job, tier(task), "model") || model_for_tier(tier(task))
    def thinking(task = :screening, job: nil) = locked(job, tier(task), "thinking") || thinking_for_tier(tier(task))
    def model_for_tier(tier) = env(TIERS.fetch(tier)[:model_key]) || env("AI_MODEL") || TIERS.fetch(tier)[:model]
    def thinking_for_tier(tier) = env(TIERS.fetch(tier)[:thinking_key]) || env("AI_THINKING") || TIERS.fetch(tier)[:thinking]
    # "Tier HIGH · gemini-3.8-pro": printed beside every AI result (rule 3), so a judge sees which model
    # produced which evidence. Shown on purpose despite the general rule that users see no model names.
    def tier_label(task, job: nil) = "Tier #{tier(task).to_s.upcase} · #{model(task, job:)}"
    # The tier → model mapping in force now, stored on the vacancy when its portal opens (rule 2).
    def tiers_snapshot = TIERS.keys.to_h { |t| [t.to_s, { "model" => model_for_tier(t), "thinking" => thinking_for_tier(t) }] }
    def locked(job, tier, key) = job&.respond_to?(:ai_model_tiers) ? job.ai_model_tiers.to_h.dig(tier.to_s, key).presence : nil

    # Boot check (rule 6): every tier resolves to a known model id, or the server does not start, with
    # the key named. Called from config/initializers/ai_models.rb.
    def validate_models!(env = ENV)
      bad = TIERS.map do |t, spec|
        id = env[spec[:model_key]].to_s.strip.presence || env["AI_MODEL"].to_s.strip.presence || spec[:model]
        "#{spec[:model_key]}=#{id.inspect}" unless KNOWN_MODELS.include?(id)
      end.compact
      return true if bad.empty?

      raise Glassbox::Settings::Invalid, "unknown Gemini model id: #{bad.join(', ')}. Known ids: #{KNOWN_MODELS.join(', ')} (Screening::Config::KNOWN_MODELS; confirm new ids with glassbox:ai:smoke and add them)"
    end

    def env(key) = ENV[key].to_s.strip.presence
    # Release first only when explicitly required; the default is the automatic mode (GlassBox Team,
    # 2026-10-13, reversing her 2026-10-12 "1a" ruling). Set AI_SCREENING_REVIEW=required on a server
    # whose client wants a reviewer to read every CV before the AI.
    def review_before_ai? = env("AI_SCREENING_REVIEW") == "required"

    # Where the credentials came from, for the runbook's verification task. Never the value.
    def key_source = client_class.credential_source

    def api_key
      from_credentials = Rails.application.credentials.dig(:ai, :api_key)
      from_credentials.to_s.strip.presence || ENV["AI_API_KEY"].to_s.strip.presence
    end

    # "credentials (ai.api_key)", "ENV AI_API_KEY" or nil. Never the key.
    def api_key_source
      return "credentials (ai.api_key)" if Rails.application.credentials.dig(:ai, :api_key).to_s.strip.present?
      return "ENV AI_API_KEY" if ENV["AI_API_KEY"].to_s.strip.present?

      nil
    end
  end
end
