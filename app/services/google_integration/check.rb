require "net/http"
require "net/smtp"

module GoogleIntegration
  # `bin/rails glassbox:google:check` (D52): one HARMLESS call per configured integration, so the team
  # knows tonight whether each credential works before anyone depends on it. Nothing is sent,
  # stored, created or changed at Google:
  # - login:    POST the OAuth token endpoint with a made-up code. Google answers "invalid_grant"
  #             when the client id/secret are right (the code is simply wrong) and "invalid_client"
  #             when they are wrong. No user, no token.
  # - mail:     SMTP connect + STARTTLS + AUTH to smtp.gmail.com:587, then QUIT. No message.
  # - storage:  read the bucket's metadata; compare its location with GOOGLE_STORAGE_REGION (UU PDP)
  #             and warn when public access prevention is not enforced.
  # - calendar: read the calendar's metadata (calendars.get), as the impersonated user.
  # Each result is written to google_integration_events, so Settings shows it. Messages
  # carry no secret: the token endpoint's answer is reduced to its error CODE.
  class Check
    Result = Data.define(:integration, :status, :message)
    TOKEN_URI = URI("https://oauth2.googleapis.com/token")
    FAILURES = (Calendar::FAILURES + [ "Net::SMTPError", "Google::Cloud::Error" ]).freeze

    def self.run = new.run

    def run
      [ check(:login, Config.login_configured?) { login },
        check(:mail, Config.mail_configured?) { mail },
        check(:storage, Config.storage_configured?) { storage },
        check(:calendar, Config.calendar_configured?) { calendar } ]
    end

    private

    def check(integration, configured)
      return Result.new(integration:, status: :off, message: "not configured") unless configured

      message = yield
      Event.record!(integration, source: :check, message:)
      Result.new(integration:, status: :ok, message:)
    rescue Failed, *FAILURES.filter_map(&:safe_constantize) => e
      text = Glassbox::GoogleKey.redact(e.is_a?(Failed) ? e.message : "#{e.class.name}: #{e.message}").truncate(300)
      Event.record!(integration, source: :check, error: e, message: text)
      Result.new(integration:, status: :failed, message: text)
    end

    class Failed < StandardError; end

    def login
      response = Net::HTTP.post_form(TOKEN_URI, "grant_type" => "authorization_code", "code" => "glassbox-check-not-a-real-code",
                                                "client_id" => Config.oauth_client_id, "client_secret" => Config.oauth_client_secret,
                                                "redirect_uri" => "https://localhost/auth/google_oauth2/callback")
      code = error_code(response.body)
      case code
      when "invalid_grant", "redirect_uri_mismatch" then "client ID and secret accepted by Google"
      when "invalid_client", "unauthorized_client" then raise Failed, "Google refused the client ID or secret (#{code})"
      else raise Failed, "unexpected answer from Google (HTTP #{response.code}, #{code.presence || 'no code'})"
      end
    end

    # The token endpoint's error code only; the rest of the body is not kept. A body that is not
    # JSON (a proxy page) has no code and is reported as "unexpected", never ignored.
    def error_code(body)
      JSON.parse(body.to_s)["error"].to_s
    rescue JSON::ParserError
      ""
    end

    def mail
      smtp = Net::SMTP.new("smtp.gmail.com", 587)
      smtp.open_timeout = 10
      smtp.read_timeout = 15
      smtp.enable_starttls
      smtp.start(Config.mail_username.split("@", 2).last, Config.mail_username, Config.mail_app_password, :plain) { }
      "Gmail SMTP login succeeded as #{Config.mail_username}"
    end

    def storage
      bucket = Client.storage.bucket(Config.storage_bucket)
      raise Failed, "bucket #{Config.storage_bucket} not found, or the service account has no access" unless bucket

      location = bucket.location.to_s.downcase
      expected = Config.storage_region
      if expected && location != expected
        raise Failed, "bucket is in #{location}, not #{expected} (UU PDP: move it before use)"
      end

      notes = [ "bucket #{bucket.name} in #{location}" ]
      notes << "region not set (GOOGLE_STORAGE_REGION)" unless expected
      notes << "WARNING: public access prevention not enforced" unless bucket.public_access_prevention.to_s == "enforced"
      notes.join("; ")
    end

    def calendar
      found = Client.calendar.get_calendar(Config.calendar_id)
      as = Config.calendar_impersonate ? "as #{Config.calendar_impersonate}" : "no delegation: invitations will not be sent"
      "calendar #{found.id} is readable (#{as})"
    end
  end
end
