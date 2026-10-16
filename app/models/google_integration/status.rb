module GoogleIntegration
  # The state of each Google integration for Settings (D52): "Not configured", "Active" or
  # "Last failed: <time>". Built from Config (configured or not), google_integration_events
  # (check task, calendar syncs, Google login errors) and the records each integration already
  # writes: Google sign-ins (sign_in_events) and mail sends (mail_deliveries).
  #
  # SECRETS: a row carries only yes/no, source NAMES ("ENV GOOGLE_OAUTH_CLIENT_SECRET") and values
  # that are not secret (bucket name, sender address, calendar id). The client secret, the app
  # password and the service-account key are never read into a row. test/models/google_integration/
  # status_test.rb renders the page with known fake secrets and asserts they are absent.
  class Status
    Row = Data.define(:key, :title, :icon, :state, :last_failure_at, :last_failure, :last_ok_at, :details) do
      def label
        case state
        when :off then "Not configured"
        when :active then "Active"
        when :failed then "Last failed: #{I18n.l(last_failure_at.in_time_zone, format: :long_wib)}"
        end
      end

      def badge = { off: "secondary", active: "success", failed: "danger" }.fetch(state)
    end

    def self.all = new.rows

    def rows = [ login, mail, storage, calendar ]

    private

    def login
      ok = SignInEvent.where(auth_method: "google", outcome: "success").maximum(:created_at)
      row("login", "Sign in with Google", "fa-sign-in", Config.login_configured?, extra_ok_at: ok, details: [
        [ "Client ID", presence(:oauth_client_id) ], [ "Client secret", presence(:oauth_client_secret) ],
        [ "Workspace domain", Config.hosted_domain || "any domain (registered emails only)" ],
        [ "Redirect URI at Google", "#{base_url}/auth/google_oauth2/callback" ]
      ])
    end

    def mail
      failed = MailDelivery.where(status: "failed").maximum(:created_at)
      sent = MailDelivery.where(status: "sent").maximum(:created_at)
      method = ActionMailer::Base.delivery_method
      row("mail", "Email via Gmail", "fa-envelope", Config.mail_configured?, extra_ok_at: sent, extra_failed_at: failed,
          extra_failure: failed && "An email failed to send. See the Work queue.", details: [
            [ "Gmail account", Config.mail_username || "not configured" ], [ "App password", presence(:mail_app_password) ],
            [ "Sender", ApplicationMailer.setting(:from, "MAIL_FROM") || "not configured" ],
            [ "Reply-to", ApplicationMailer.setting(:reply_to, "MAIL_REPLY_TO") || "-" ],
            [ "Current delivery method", method == :smtp ? "SMTP #{ActionMailer::Base.smtp_settings[:address]}" : "#{method} (not production)" ]
          ])
    end

    def storage
      active = Config.storage_configured? && Config.storage_active?
      row("storage", "Files in Google Cloud Storage", "fa-cloud", active, details: [
        [ "Bucket", Config.storage_bucket || "not configured" ], [ "Service account", presence(:service_account_json) ],
        [ "Expected region", Config.storage_region || "not configured (recommended: #{Config::RECOMMENDED_REGION}, Jakarta)" ],
        [ "New files are stored in", Config.storage_active? ? "Google Cloud Storage" : "the server's local disk" ]
      ])
    end

    def calendar
      row("calendar", "Google Calendar invitations", "fa-calendar", Config.calendar_configured?, details: [
        [ "Calendar", Config.calendar_id || "not configured" ], [ "Service account", presence(:service_account_json) ],
        [ "Acts as", Config.calendar_impersonate || "not configured (without it Google sends no invitations)" ]
      ])
    end

    def row(key, title, icon, configured, details:, extra_ok_at: nil, extra_failed_at: nil, extra_failure: nil)
      last_fail_event = Event.where(integration: key, outcome: "failed").order(created_at: :desc, id: :desc).first
      last_ok_event_at = Event.where(integration: key, outcome: "ok").maximum(:created_at)
      failure_at = [ last_fail_event&.created_at, extra_failed_at ].compact.max
      failure = if failure_at && failure_at == last_fail_event&.created_at then last_fail_event.message.presence || last_fail_event.error_class
      else extra_failure
      end
      ok_at = [ last_ok_event_at, extra_ok_at ].compact.max
      state = if !configured then :off
      elsif failure_at && (ok_at.nil? || failure_at > ok_at) then :failed
      else :active
      end
      Row.new(key:, title:, icon:, state:, last_failure_at: failure_at, last_failure: failure, last_ok_at: ok_at, details:)
    end

    def presence(name)
      source = Config.source(name)
      source ? "configured (#{source})" : "not configured"
    end

    def base_url
      options = Rails.application.config.action_mailer.default_url_options || {}
      host = ENV["APP_HOST"].presence || options[:host] || "localhost"
      port = options[:port] && !ENV["APP_HOST"].present? ? ":#{options[:port]}" : ""
      "#{host.start_with?('http') ? '' : 'https://'}#{host}#{port}"
    end
  end
end
