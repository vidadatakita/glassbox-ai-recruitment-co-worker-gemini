module GoogleIntegration
  # D52 (4): an appointment as a Google Calendar event, with the candidate and the interviewer as
  # attendees and the invitation e-mails sent BY GOOGLE (sendUpdates=all).
  #
  # Rules:
  # - Called only AFTER the appointment is committed (Staff::AppointmentsController). A Google
  #   failure never undoes or blocks the save: it is stored on the appointment
  #   (calendar_status "failed", shown as "Undangan kalender gagal dikirim") and in
  #   google_integration_events, and the consultant presses "Kirim ulang undangan".
  # - The event text holds the stage, the candidate's NAME and the JOB TITLE, the time, the place or
  #   video link, what to bring and the contact. Never a score, a decision, AI output, the
  #   candidate's reschedule reason or any other free text written by the candidate (D52, D51).
  # - Interviewer = the consultant who last saved the schedule (latest AppointmentChange). The app
  #   has no interviewer list per appointment yet; recorded as open in the feature record.
  # - Off (returns :off, touches nothing) until GOOGLE_CALENDAR_ID and the service account are set.
  #
  # Synchronous like MailDelivery, so the screen that saved the schedule says at once whether the
  # invite went out. Timeouts are short and the client does not retry by itself, so a slow Google
  # costs the consultant at most about 25 seconds, once.
  class Calendar
    SCOPE = "https://www.googleapis.com/auth/calendar.events".freeze
    TIME_ZONE = "Asia/Jakarta".freeze

    # Failures caused by Google, the network or the credentials. Anything else (a NoMethodError, a
    # broken template) is a programming error and is NOT caught, so it fails loudly in tests.
    FAILURES = [
      "Google::Apis::Error", "Google::Auth::Error", "Signet::AuthorizationError", "Signet::RemoteServerError",
      "Signet::UnexpectedStatusError", "Faraday::Error", "JSON::ParserError", "Glassbox::GoogleKey::Invalid", "OpenSSL::OpenSSLError",
      "SocketError", "SystemCallError", "IOError", "Timeout::Error"
    ].freeze

    def self.sync(appointment) = new(appointment).sync
    def self.cancel(appointment) = new(appointment).cancel

    def initialize(appointment, service: nil)
      @appointment = appointment
      @service = service
    end

    # Creates the event, or updates it when the appointment already has one. Returns :off,
    # :synced or :failed.
    def sync
      return :off unless Config.calendar_configured?

      guard do
        event = build_event
        saved = if @appointment.calendar_event_id.present?
                  update_or_recreate(event)
        else
                  service.insert_event(Config.calendar_id, event, send_updates: "all")
        end
        @appointment.update_columns(calendar_event_id: saved.id, calendar_status: "synced", calendar_error: nil,
                                    calendar_synced_at: Time.current)
        :synced
      end
    end

    # Deletes the event; Google e-mails the attendees that it is cancelled. Used when the candidate
    # withdraws consent (Pasal 40: processing stops). Returns :off, :none, :cancelled or :failed.
    def cancel
      return :off unless Config.calendar_configured?
      return :none if @appointment.calendar_event_id.blank?

      guard do
        begin
          service.delete_event(Config.calendar_id, @appointment.calendar_event_id, send_updates: "all")
        rescue ::Google::Apis::ClientError => e
          # 404/410: the event is already gone (deleted by hand in Google Calendar). That is the
          # outcome we wanted, so it is not a failure.
          raise unless [ 404, 410 ].include?(e.status_code)
        end
        @appointment.update_columns(calendar_status: "cancelled", calendar_error: nil, calendar_synced_at: Time.current)
        :cancelled
      end
    end

    private

    def guard
      result = yield
      Event.record!(:calendar, source: :sync)
      result
    rescue *FAILURES.filter_map(&:safe_constantize) => e
      message = Glassbox::GoogleKey.redact("#{e.class.name}: #{e.message}").truncate(500)
      @appointment.update_columns(calendar_status: "failed", calendar_error: message, calendar_synced_at: Time.current)
      Event.record!(:calendar, source: :sync, error: e, message:)
      Rails.logger.warn("[google-calendar] appointment=#{@appointment.id} failed: #{e.class.name}")
      :failed
    end

    def update_or_recreate(event)
      service.update_event(Config.calendar_id, @appointment.calendar_event_id, event, send_updates: "all")
    rescue ::Google::Apis::ClientError => e
      # The event was deleted by hand in Google: make a new one rather than fail forever on retry.
      raise unless [ 404, 410 ].include?(e.status_code)

      service.insert_event(Config.calendar_id, event, send_updates: "all")
    end

    def build_event
      require "google/apis/calendar_v3"
      participation = @appointment.participation
      application = participation.job_application
      stage = CandidateStatus::STAGE_LABELS.fetch(participation.stage.code)
      lines = [
        "#{stage} appointment for the position #{application.job.title}.",
        "Mode: #{Appointment::MODES.fetch(@appointment.mode)}.",
        "#{@appointment.mode == 'video' ? 'Link' : 'Place'}: #{@appointment.place_or_link}",
        (@appointment.bring.present? ? "What to bring: #{@appointment.bring}" : nil),
        "Contact: #{@appointment.contact}",
        "Confirm your attendance through the application status link in the GlassBox email."
      ].compact
      ::Google::Apis::CalendarV3::Event.new(
        summary: "#{stage}: #{application.candidate.name} · #{application.job.title}",
        description: lines.join("\n"),
        location: @appointment.place_or_link,
        start: ::Google::Apis::CalendarV3::EventDateTime.new(date_time: @appointment.starts_at.in_time_zone(TIME_ZONE).iso8601, time_zone: TIME_ZONE),
        end: ::Google::Apis::CalendarV3::EventDateTime.new(date_time: @appointment.ends_at.in_time_zone(TIME_ZONE).iso8601, time_zone: TIME_ZONE),
        attendees: attendee_emails(application).map { |email| ::Google::Apis::CalendarV3::EventAttendee.new(email:) },
        guests_can_see_other_guests: false,
        reminders: ::Google::Apis::CalendarV3::Event::Reminders.new(use_default: true)
      )
    end

    def attendee_emails(application)
      actor_id = @appointment.appointment_changes.order(:created_at, :id).last&.actor_id
      interviewer = actor_id && User.find_by(id: actor_id)
      [ application.candidate.email, interviewer&.email_address ].compact.map(&:downcase).uniq
    end

    def service
      @service ||= GoogleIntegration::Client.calendar
    end
  end
end
