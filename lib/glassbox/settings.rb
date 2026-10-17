# frozen_string_literal: true

module Glassbox
  # The settings registry (on-prem spec ONP-2, decision D34). Every installation setting is
  # declared here, once: where it comes from, whether it is required, and what values it takes.
  #
  # Two sources, never mixed (ONP-3):
  # - ENV_KEYS are read from the environment (Kamal secrets or the release bundle's .env), owned
  #   by the client's IT. The app refuses to boot when a required one is missing or invalid.
  # - SCREEN_KEYS live in the system_settings table and are changed on Pengaturan Sistem, with
  #   an audit row per change (SettingChange).
  #
  # A key read anywhere in app/, config/ or lib/ must be declared here; test/lib/settings_registry_test.rb
  # scans the code and fails on an undeclared ENV read.
  module Settings
    class Invalid < StandardError; end

    ENV_KEYS = {
      # Product settings (Appendix B of the on-prem spec; more are added by later plans).
      "TENANCY" => { required: true, values: %w[single multi], about: "single = one client company per install (client-side); multi = subscription" },
      # A5 (Cup rule "works without login"): 1 = the public demo (no-login door at /demo, nightly reset).
      # Optional and off by default ON PURPOSE: a client install must never carry an open door by accident.
      "DEMO_MODE" => { required: false, values: %w[0 1], about: "1 = public demo: no-login door at /demo and the nightly reset are on; default 0" },
      # Pauses ONLY the scheduled nightly reset (DemoResetJob), never the on-demand rake task: set it
      # for the claims check and the video recording, so the workspace does not vanish mid-scene.
      # Development only: also seed the earlier feature demos (Indonesian titles). Never on the public demo.
      "LEGACY_DEMO_SEEDS" => { required: false, values: %w[0 1], about: "1 = db:seed also loads the earlier feature demos with Indonesian content (development only); default 0" },
      "DEMO_RESET" => { required: false, values: %w[on off], about: "off = the scheduled nightly demo reset is skipped (the rake task glassbox:demo:reset still runs on demand); default on" },
      # Connection settings read by config/database.yml.
      "DATABASE_HOST" => { required: false, about: "PostgreSQL host; default localhost" },
      "DATABASE_PORT" => { required: false, about: "PostgreSQL port; default 5432" },
      "DATABASE_USER" => { required: false, about: "PostgreSQL user; the password comes from ~/.pgpass or the server's own auth" },
      "TEST_DATABASE" => { required: false, about: "test database name, so a parallel test run uses its own database" },
      "GLASSBOX_DATABASE_PASSWORD" => { required: false, about: "production database password (Rails generator default)" },
      # Framework settings written by the Rails 8.1 generator (Puma, Solid Queue, logging, CI).
      "RAILS_MAX_THREADS" => { required: false, about: "framework" },
      "BUNDLE_GEMFILE" => { required: false, about: "framework (config/boot.rb)" },
      "RAILS_ENV" => { required: false, about: "framework" },
      "RAILS_LOG_LEVEL" => { required: false, about: "framework" },
      "PORT" => { required: false, about: "framework" },
      "PIDFILE" => { required: false, about: "framework" },
      "SOLID_QUEUE_IN_PUMA" => { required: false, about: "framework" },
      "JOB_CONCURRENCY" => { required: false, about: "framework" },
      "WEB_CONCURRENCY" => { required: false, about: "framework" },
      "CI" => { required: false, about: "framework" },
      "PARALLEL_WORKERS" => { required: false, about: "framework" },
      "RAILS_MASTER_KEY" => { required: false, about: "framework" },
      "APP_HOST" => { required: false, about: "host name used in links inside emails; default localhost:3000" },
      # Feature 06, S1 AI screening (D50). Optional ON PURPOSE: without a key the AI is off and the
      # screens say so ("Screening AI belum aktif"); the app must still boot. Rails credentials
      # ai.api_key wins over AI_API_KEY (Screening::Config). Never logged, never shown.
      # Google products only (AI Builder Cup rule): gemini is the one accepted value.
      "AI_PROVIDER" => { required: false, values: %w[gemini], about: "AI provider: gemini (Gemini API with AI_API_KEY, or Vertex AI with the service account)" },
      "AI_API_KEY" => { required: false, about: "the Gemini API key; unset = Vertex AI with GOOGLE_SERVICE_ACCOUNT_JSON, or AI screening off when neither is set (secret)" },
      "AI_MODEL" => { required: false, about: "Gemini model id for every tier at once; unset = each tier's default (Screening::Config::TIERS)" },
      "AI_THINKING" => { required: false, values: %w[low medium high], about: "thinking level for every tier at once; unset = each tier's default" },
      # FLOW §9 model tiers: HIGH (judgements a person acts on), MEDIUM (structured drafting), LOW (short text).
      # A configured id must be in Screening::Config::KNOWN_MODELS or the server does not start.
      "AI_MODEL_HIGH" => { required: false, about: "Gemini model id of the HIGH tier (CV scoring, test scoring, stage advice, fairness); default gemini-3.8-flash" },
      "AI_MODEL_MEDIUM" => { required: false, about: "Gemini model id of the MEDIUM tier (brief suggestion, discrimination test, red flags); default gemini-3.8-flash" },
      "AI_MODEL_LOW" => { required: false, about: "Gemini model id of the LOW tier (ad drafting and scan, letters, chat); default gemini-3.5-flash-lite" },
      "AI_THINKING_HIGH" => { required: false, values: %w[low medium high], about: "thinking level of the HIGH tier; default medium" },
      "AI_THINKING_MEDIUM" => { required: false, values: %w[low medium high], about: "thinking level of the MEDIUM tier; default medium" },
      "AI_THINKING_LOW" => { required: false, values: %w[low medium high], about: "thinking level of the LOW tier; default low" },
      "AI_SCREENING_REVIEW" => { required: false, values: %w[auto required], about: "auto (default): AI screens each CV as it arrives, people decide on the result; required: a reviewer releases each CV before the AI sees it" },
      "AI_API_KEY_ENDPOINT" => { required: false, values: %w[gemini vertex], about: "gemini (default): AI_API_KEY is an AI Studio key; vertex: it is a Vertex AI express-mode key" },
      "GOOGLE_CLOUD_PROJECT" => { required: false, about: "Vertex AI project of an express-mode AI_API_KEY (id or number); unset = Google picks the location" },
      "GOOGLE_CLOUD_LOCATION" => { required: false, about: "Vertex AI location for Gemini; default global" },
      # D52 Google integrations. ALL optional ON PURPOSE: each integration is off until its keys are
      # set (GoogleIntegration::Config); Rails credentials google.<name> win over these variables.
      # Secrets (client secret, app password, service-account JSON) are never logged or shown.
      "GOOGLE_OAUTH_CLIENT_ID" => { required: false, about: "Login with Google: OAuth client id; unset = no Google button" },
      "GOOGLE_OAUTH_CLIENT_SECRET" => { required: false, about: "Login with Google: OAuth client secret (secret)" },
      "GOOGLE_LOGIN_HOSTED_DOMAIN" => { required: false, about: "Login with Google: only accounts of this Workspace domain may sign in (optional)" },
      "GOOGLE_MAIL_USERNAME" => { required: false, about: "Gmail SMTP: the Workspace mailbox that sends (production only)" },
      "GOOGLE_MAIL_APP_PASSWORD" => { required: false, about: "Gmail SMTP: the mailbox's 16-character app password (secret)" },
      "MAIL_FROM" => { required: false, about: "sender address of every email; must be the Gmail mailbox or one of its aliases" },
      "MAIL_REPLY_TO" => { required: false, about: "reply-to address of every email (optional)" },
      "GOOGLE_SERVICE_ACCOUNT_JSON" => { required: false, about: "storage + calendar: the service account key file CONTENT, one line of JSON (secret)" },
      "GLASSBOX_STORAGE_SERVICE" => { required: false, values: %w[local google], about: "where new files are stored; default local; google needs the bucket and service account" },
      "GOOGLE_STORAGE_BUCKET" => { required: false, about: "Cloud Storage bucket name (private bucket)" },
      "GOOGLE_STORAGE_REGION" => { required: false, about: "the bucket region the check task must find (UU PDP; recommended asia-southeast2 Jakarta)" },
      "GOOGLE_CALENDAR_ID" => { required: false, about: "Google Calendar id that receives appointment events" },
      "GOOGLE_CALENDAR_IMPERSONATE" => { required: false, about: "Workspace user the service account acts as (domain-wide delegation); needed for invites" },
      "DRY_RUN" => { required: false, values: %w[0 1], about: "glassbox:google:migrate_storage only: 0 copies, anything else lists (default 1)" }
    }.freeze

    # Screen settings. No default for the retention period ON PURPOSE (D32, ONP-23): the consent
    # must state it (UU 27/2022 Pasal 21(1) d), so the portal cannot open until someone with the
    # authority sets it. Giving it a default would publish a legal promise nobody made.
    SCREEN_KEYS = {
      "retention_days" => { type: :integer, default: nil, min: 1, label: "Applicant data retention (days after the vacancy closes)" },
      # ONP-14 / Q10: off on client-side installs until GlassBox Team decides; DataKita does not verify a
      # company on a server it does not run.
      # Which CV parts may go to the AI (Screening::CvSections::GROUPS); personal data never can.
      # Default = the D51 A list. At least one must stay chosen.
      "ai_cv_sections" => { type: :list, values: %w[experience education skills certifications projects activities summary],
                            default: %w[experience education skills certifications], label: "CV sections sent to the AI" },
      "verified_line" => { type: :boolean, default: false, label: "Show the \"Verified by GlassBox\" line on the Apply page" },
      # AI interview before CV screening (docs/features/05-ai-interview.md). Off until
      # the consent text names the interview (UU PDP Pasal 21): with it off, no interview exists and the
      # apply flow is exactly as before.
      "ai_interview" => { type: :boolean, default: false, label: "AI interview before CV screening" },
      # AI Builder Cup "before / after" (Ringkasan Dampak): the BEFORE side is what the client measured
      # without GlassBox (interview, survey); no default, so no number is ever invented.
      "baseline_hours_to_answer" => { type: :integer, default: nil, min: 1, label: "Before: hours from application to first answer" },
      "baseline_minutes_per_cv" => { type: :integer, default: nil, min: 1, label: "Before: recruiter minutes per CV" },
      "baseline_reasoned_pct" => { type: :integer, default: nil, min: 0, max: 100, label: "Before: percent of decisions with a written reason" }
    }.freeze

    # Rate limits on the public candidate pages (D41, 2026-10-10). GUESS, MEASURE IN T0: no traffic
    # has been observed yet. Per-IP limits are an abuse guard only, because on Indonesian mobile data
    # many candidates share one carrier IP (CGNAT) and a tight per-IP limit turns real applicants
    # away. The tighter limit is per Lamar form instance (the signed consent token of step 2), so one
    # script hammering one form is throttled without punishing a whole carrier address. Every
    # correctness rule (window, quota, consent token, PDF check) is enforced on each request anyway.
    RATE_LIMITS = {
      lamar_per_ip: { to: 120, within: 60 },          # requests per IP to Lamar steps 1 and 2, per 60 s
      lamar_per_form: { to: 10, within: 600 },        # step-2 submits per form instance, per 600 s
      link_request_per_ip: { to: 30, within: 600 },   # "Minta link baru" per IP, per 600 s
      # D60 technical test, counted per STATUS LINK (not per IP: carrier NAT, test engine G3).
      # "Mulai tes" is idempotent, so the start limit only stops scripted hammering; the answer limit
      # bounds upload attempts (each refused file costs an inspection); the case-file limit bounds
      # downloads of the case. Guesses like the others: measure in T0.
      test_start_per_link: { to: 10, within: 600 },
      test_answer_per_link: { to: 10, within: 600 },
      test_case_file_per_link: { to: 30, within: 600 },
      # The AI interview chat, counted per status link like the test: each answer costs a paid model call.
      interview_start_per_link: { to: 10, within: 600 },
      interview_answer_per_link: { to: 20, within: 300 }
    }.freeze

    module_function

    # Returns the list of problems; empty when the environment is valid.
    def problems(env)
      ENV_KEYS.filter_map do |key, spec|
        value = env[key]
        if value.nil? || value.strip.empty?
          "#{key} is required (#{spec[:values]&.join(' or ') || 'a value'}): #{spec[:about]}" if spec[:required]
        elsif spec[:values] && !spec[:values].include?(value)
          "#{key}=#{value.inspect} is invalid; expected #{spec[:values].join(' or ')}"
        end
      end
    end

    # Called at boot (config/initializers/glassbox_settings.rb). Raising here stops the server
    # with the key's name, which is the point: a half-configured install must not start.
    def validate!(env)
      found = problems(env)
      raise Invalid, "GlassBox cannot start: #{found.join('; ')}" if found.any?

      true
    end

    def tenancy(env = ENV)
      env.fetch("TENANCY")
    end

    # A5: the public demo switch. Read at boot by config/routes.rb (the demo door is only drawn here)
    # and at request time by DemoSessionsController and Demo::Reset (both refuse outside demo mode).
    def demo_mode?(env = ENV) = env["DEMO_MODE"].to_s.strip == "1"
    def demo_reset_paused?(env = ENV) = env["DEMO_RESET"].to_s.strip == "off"
    def legacy_demo_seeds?(env = ENV) = env["LEGACY_DEMO_SEEDS"].to_s.strip == "1" && !demo_mode?(env)

    def multi_tenant?(env = ENV) = env.fetch("TENANCY", "single") == "multi"

    # The client company whose own settings and consent text a user writes: theirs under
    # TENANCY=multi; nil (install-wide) under single, where there is one company anyway.
    def settings_company_id(user, env = ENV) = multi_tenant?(env) ? user&.client_company_id : nil
  end
end
