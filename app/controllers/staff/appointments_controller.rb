module Staff
  # Schedules (BP §3.6 B3). Only the consultant schedules. A changed time resets the confirmation
  # and logs the old time (§3.6 C).
  class AppointmentsController < BaseController
    before_action -> { require_role!(:hr_admin) }

    def create
      participation = org_find(Participation, params[:participation_id])
      # D40: no appointment for an application whose consent was withdrawn (Pasal 40).
      if participation.job_application.consent_withdrawn_at
        return redirect_to(staff_application_path(participation.job_application_id),
                           alert: "The applicant has withdrawn consent to the use of their data. No appointment can be created.")
      end
      appointment = participation.build_appointment(appointment_params.merge(confirmation: "pending"))
      Appointment.transaction do
        appointment.save!
        AppointmentChange.create!(appointment:, old_starts_at: nil, new_starts_at: appointment.starts_at,
                                  actor_id: current_user.id, created_at: Time.current)
      end
      redirect_to staff_application_path(participation.job_application_id), notice: with_calendar("Appointment saved.", appointment)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to staff_application_path(participation.job_application_id), alert: e.record.errors.full_messages.to_sentence
    end

    def update
      appointment = org_find(Appointment, params[:id])
      if appointment.participation.job_application.consent_withdrawn_at
        return redirect_to(staff_application_path(appointment.participation.job_application_id),
                           alert: "The applicant has withdrawn consent to the use of their data. The appointment cannot be changed.")
      end
      old_start = appointment.starts_at
      Appointment.transaction do
        appointment.assign_attributes(appointment_params)
        time_changed = appointment.starts_at_changed? || appointment.ends_at_changed?
        appointment.confirmation = "pending" if time_changed
        appointment.save!
        if time_changed
          AppointmentChange.create!(appointment:, old_starts_at: old_start, new_starts_at: appointment.starts_at,
                                    actor_id: current_user.id, created_at: Time.current)
        end
      end
      redirect_to staff_application_path(appointment.participation.job_application_id), notice: with_calendar("Appointment updated.", appointment)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to staff_application_path(appointment.participation.job_application_id), alert: e.record.errors.full_messages.to_sentence
    end

    # D52 (4): "Resend invitation" after a failed calendar sync. Same role as scheduling.
    def calendar
      appointment = org_find(Appointment, params[:id])
      application_id = appointment.participation.job_application_id
      # After a consent withdrawal the only allowed Google action is DELETING the event (Pasal 40);
      # a failed cancel must stay retryable, or the candidate's name and time stay in Google
      # (test engine F-10-02). Never re-send an invite to someone who withdrew.
      return retry_cancel(appointment, application_id) if appointment.participation.job_application.consent_withdrawn_at

      result = GoogleIntegration::Calendar.sync(appointment)
      if result == :synced
        redirect_to staff_application_path(application_id), notice: "Calendar invitation sent."
      else
        redirect_to staff_application_path(application_id),
                    alert: result == :off ? "Google Calendar is not configured." : "The calendar invitation could not be sent. Try again later or contact the admin."
      end
    end

    private

    def retry_cancel(appointment, application_id)
      case GoogleIntegration::Calendar.cancel(appointment)
      when :cancelled, :none
        redirect_to staff_application_path(application_id), notice: "Calendar invitation cancelled."
      when :off
        redirect_to staff_application_path(application_id), alert: "Google Calendar is not configured."
      else
        redirect_to staff_application_path(application_id), alert: "Cancelling the calendar invitation failed. Try again later or contact the admin."
      end
    end

    # D52 (4): the calendar invite is sent AFTER the schedule is committed, so a Google failure
    # never undoes the save. The flash says both facts; the failure also stays on the appointment.
    def with_calendar(message, appointment)
      case GoogleIntegration::Calendar.sync(appointment)
      when :synced then "#{message} Calendar invitation sent."
      when :failed
        flash[:alert] = "The calendar invitation could not be sent. Press \"Resend invitation\" on the appointment."
        message
      else message
      end
    end

    def appointment_params
      permitted = params.require(:appointment).permit(:starts_at, :ends_at, :mode, :place_or_link, :bring, :contact)
      %i[starts_at ends_at].each { |k| permitted[k] = Time.zone.parse(permitted[k]) if permitted[k].present? }
      permitted
    end
  end
end
