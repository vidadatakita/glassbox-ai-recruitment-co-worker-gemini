module GoogleIntegration
  # Where each Google integration (D52) reads its credentials, and whether it is switched on.
  #
  # Every value comes from Rails credentials (the `google:` block) first, then from the server
  # environment. Nothing is ever read from the database, a screen or the repository. Every method
  # here that a screen or a log may call returns a yes/no or a SOURCE NAME, never the value: the
  # settings page and `glassbox:google:check` must be able to say "configured from ENV" without
  # being able to print a secret.
  #
  # An integration with no credentials is OFF and harmless: no button, no call, no change to how
  # mail, files or appointments work today. Every ENV key is declared in lib/glassbox/settings.rb.
  #
  # Namespace note: the Google gems own the root modules `Google::Apis` and `Google::Cloud`, so this
  # code lives under GoogleIntegration, never under Google.
  module Config
    # credentials key (under google:) => ENV key
    KEYS = {
      oauth_client_id: "GOOGLE_OAUTH_CLIENT_ID",
      oauth_client_secret: "GOOGLE_OAUTH_CLIENT_SECRET",
      hosted_domain: "GOOGLE_LOGIN_HOSTED_DOMAIN",
      mail_username: "GOOGLE_MAIL_USERNAME",
      mail_app_password: "GOOGLE_MAIL_APP_PASSWORD",
      service_account_json: "GOOGLE_SERVICE_ACCOUNT_JSON",
      storage_bucket: "GOOGLE_STORAGE_BUCKET",
      storage_region: "GOOGLE_STORAGE_REGION",
      calendar_id: "GOOGLE_CALENDAR_ID",
      calendar_impersonate: "GOOGLE_CALENDAR_IMPERSONATE"
    }.freeze

    # Bucket region expected for UU PDP (D52: "region to be confirmed"). Jakarta is the
    # recommendation, not a decision: the check task compares the bucket's real location with
    # GOOGLE_STORAGE_REGION when that is set, and only warns when it is not.
    RECOMMENDED_REGION = "asia-southeast2".freeze

    module_function

    def value(name)
      env_key = KEYS.fetch(name)
      from_credentials = Rails.application.credentials.dig(:google, name)
      from_credentials.to_s.strip.presence || ENV[env_key].to_s.strip.presence
    end

    # "credentials (google.x)", "ENV X" or nil. Never the value.
    def source(name)
      return "credentials (google.#{name})" if Rails.application.credentials.dig(:google, name).to_s.strip.present?
      return "ENV #{KEYS.fetch(name)}" if ENV[KEYS.fetch(name)].to_s.strip.present?

      nil
    end

    # --- Login with Google (staff only) -------------------------------------------------------
    def login_configured? = value(:oauth_client_id).present? && value(:oauth_client_secret).present?
    def oauth_client_id = value(:oauth_client_id)
    def oauth_client_secret = value(:oauth_client_secret)
    # Optional. When set, only accounts whose ID-token `hd` claim equals it may sign in.
    def hosted_domain = value(:hosted_domain)&.downcase

    # --- Email through Gmail / Google Workspace SMTP ------------------------------------------
    def mail_configured? = value(:mail_username).present? && value(:mail_app_password).present?
    def mail_username = value(:mail_username)
    def mail_app_password = value(:mail_app_password)

    # Switches the given mailer class to Gmail SMTP when, and only when, this is production and the
    # mailbox + app password are set. Returns true when it switched. Called once at boot.
    def apply_mail!(mailer, production:)
      return false unless production && mail_configured?

      mailer.delivery_method = :smtp
      mailer.raise_delivery_errors = true
      mailer.smtp_settings = {
        address: "smtp.gmail.com", port: 587, domain: mail_username.split("@", 2).last,
        user_name: mail_username, password: mail_app_password,
        authentication: :plain, enable_starttls: true, open_timeout: 10, read_timeout: 15
      }
      true
    end

    # --- Service account (storage and calendar) ----------------------------------------------
    # The JSON key file's CONTENT (not a path), so it can live in credentials or one ENV value.
    # Returns a Hash or nil. A malformed JSON raises Glassbox::GoogleKey::Invalid, whose message
    # names only line/column, never the key (F-10-01); the check, the calendar sync and the boot
    # guard report it as a failure.
    def service_account
      raw = value(:service_account_json)
      raw && Glassbox::GoogleKey.parse(raw)
    end

    def service_account_present? = value(:service_account_json).present?

    # --- Files in Google Cloud Storage ---------------------------------------------------------
    def storage_configured? = service_account_present? && value(:storage_bucket).present?
    def storage_bucket = value(:storage_bucket)
    def storage_region = value(:storage_region)&.downcase
    # Which Active Storage service new files go to. "local" unless GLASSBOX_STORAGE_SERVICE=google.
    def storage_service = ENV["GLASSBOX_STORAGE_SERVICE"].to_s.strip.presence || "local"
    def storage_active? = storage_service == "google"

    # Boot check (config/initializers/google_integrations.rb). Only when "google" is selected:
    # bucket and service account must be set, and the key must parse. The message never holds the key.
    def validate_storage!
      return true unless storage_active?

      unless storage_configured?
        raise Glassbox::Settings::Invalid,
              "GlassBox cannot start: GLASSBOX_STORAGE_SERVICE=google needs GOOGLE_STORAGE_BUCKET and " \
              "GOOGLE_SERVICE_ACCOUNT_JSON (or google.storage_bucket / google.service_account_json in credentials)"
      end
      service_account
      true
    rescue Glassbox::GoogleKey::Invalid => e
      raise Glassbox::Settings::Invalid, "GlassBox cannot start: GOOGLE_SERVICE_ACCOUNT_JSON: #{e.message}", cause: nil
    end

    # --- Google Calendar invites ---------------------------------------------------------------
    def calendar_configured? = service_account_present? && value(:calendar_id).present?
    def calendar_id = value(:calendar_id)
    # The Workspace user the service account acts as (domain-wide delegation). Without it Google
    # refuses attendees, so no invite can be sent; see the runbook.
    def calendar_impersonate = value(:calendar_impersonate)

    def configured?(integration)
      case integration.to_s
      when "login" then login_configured?
      when "mail" then mail_configured?
      when "storage" then storage_configured? && storage_active?
      when "calendar" then calendar_configured?
      else raise ArgumentError, "unknown integration #{integration}"
      end
    end
  end
end
