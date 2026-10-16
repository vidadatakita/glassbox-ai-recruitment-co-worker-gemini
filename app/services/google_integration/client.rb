module GoogleIntegration
  # Builds the Google API clients from the service account in Config. The gems are required here,
  # not at boot (Gemfile require: false), so an install that never switches Google on never loads
  # them.
  module Client
    module_function

    # Calendar API acting as GOOGLE_CALENDAR_IMPERSONATE (domain-wide delegation). Without
    # impersonation the service account acts as itself: events can be written to a calendar shared
    # with it, but Google refuses attendees, so no invite is sent (runbook §4).
    def calendar
      require "google/apis/calendar_v3"
      require "googleauth"

      credentials = service_account_credentials(Calendar::SCOPE, subject: Config.calendar_impersonate)
      ::Google::Apis::CalendarV3::CalendarService.new.tap do |service|
        service.authorization = credentials
        service.client_options.application_name = "GlassBox"
        service.client_options.open_timeout_sec = 10
        service.client_options.read_timeout_sec = 15
        service.client_options.send_timeout_sec = 15
        service.request_options.retries = 0
      end
    end

    # Cloud Storage client (the check and the migration task; Active Storage builds its own from
    # config/storage.yml).
    def storage
      require "google/cloud/storage"

      key = Config.service_account
      ::Google::Cloud::Storage.new(project_id: key["project_id"], credentials: key, timeout: 15, retries: 0)
    end

    def service_account_credentials(scope, subject: nil)
      require "googleauth"

      ::Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: StringIO.new(Config.service_account.to_json), scope:).tap do |creds|
        creds.sub = subject if subject.present?
      end
    end
  end
end
