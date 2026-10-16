module Portal
  # Everything a candidate can do from their status link (BP §3.6 B3–B6; D33, D36). Each method
  # checks that the object belongs to this application, so a valid link for one application can
  # never act on another's appointment, offer or participation.
  class CandidateActions
    class Refused < StandardError; end

    def initialize(application, now: Time.current)
      @application = application
      @now = now
    end

    def confirm_appointment!(appointment_id)
      appointment = own_appointment(appointment_id)
      appointment.update!(confirmation: "confirmed", reschedule_reason: nil)
      appointment
    end

    def request_reschedule!(appointment_id, reason)
      refuse!("Write the reason you are asking for another time.") if reason.to_s.strip.empty?
      appointment = own_appointment(appointment_id)
      appointment.update!(confirmation: "reschedule_requested", reschedule_reason: reason.strip)
      appointment
    end

    # One response per version, atomically: the UPDATE only matches a row still unanswered, so a
    # double tap or two tabs cannot record two answers. The unique partial index stops a second
    # acceptance across versions.
    def respond_to_offer!(offer_id, response:, reason: nil)
      offer = @application.offer_documents.find_by(id: offer_id) || refuse!("Offer not found.")
      refuse!("This offer has been replaced by a newer version.") unless offer.latest?
      refuse!("Unknown answer.") unless OfferDocument::RESPONSES.include?(response)
      refuse!("Write the reason you are declining the offer.") if response == "declined" && reason.to_s.strip.empty?
      refuse!("This offer has expired.") if offer.valid_until < @now.in_time_zone.to_date

      updated = OfferDocument.where(id: offer.id, response: nil)
                             .update_all(response:, response_reason: reason.to_s.strip.presence,
                                         responded_at: @now, updated_at: @now)
      refuse!("You have already answered this offer.") if updated.zero?

      # Hook for billing (D20, D33): the 30% invoice is created from an accepted offer in Plan 7.
      # Nothing subscribes yet; the event exists so Plan 7 attaches to it rather than to this code.
      ActiveSupport::Notifications.instrument("offer_accepted.glassbox", offer_id: offer.id) if response == "accepted"
      offer.reload
    end

    # E21: only on a closed S1 stage where this application was eliminated; one open objection.
    def object!(participation_id, text)
      participation = @application.participations.find_by(id: participation_id) || refuse!("Stage not found.")
      refuse!("An objection can only be raised against the CV screening result.") unless participation.stage.code == "S1"
      refuse!("The result of this stage is not final yet.") unless participation.stage.status == "closed"
      refuse!("An objection is only possible against a not-passed result.") unless participation.current_decision&.outcome == "eliminate"
      refuse!("Write your objection.") if text.to_s.strip.empty?
      refuse!("Your objection is being reviewed.") if participation.objections.open.exists?

      Objection.create!(participation:, text: text.strip, received_at: @now)
    end

    # Pasal 40: processing stops when consent is withdrawn. The link dies now (well inside the
    # 3 x 24 hours), the application leaves the process. Deleting the data itself is the
    # retention job (Plan 6), which treats a withdrawal like the end of the retention period.
    def withdraw_consent!
      ActiveRecord::Base.transaction do
        @application.update!(consent_withdrawn_at: @now, status: "withdrawn")
        OneTimeLink.where(subject: @application, revoked_at: nil).update_all(revoked_at: @now, updated_at: @now)
        decide_withdrawal_on_open_stages
        # Feature 09 (F09-04, Pasal 40): every stored copy of the CV text (release texts, AI quotes,
        # stage notes, the extracted text) is erased in the same transaction, the CV file after the
        # commit (who: the candidate, recorded as actor NULL; scores, decisions, digests stay). A
        # failure rolls the withdrawal back, so it is never half done.
        CandidateErasure.call(application: @application, reason: "consent_withdrawn")
      end
      # D52 (4): delete the Google Calendar invites too (Pasal 40). After the commit, so a Google
      # failure can never undo the withdrawal; a failure is stored on the appointment. A no-op
      # while Google Calendar is not configured.
      Appointment.joins(:participation).where(participations: { job_application_id: @application.id })
                 .find_each { |appointment| GoogleIntegration::Calendar.cancel(appointment) }
    end

    private

    # A withdrawal is an elimination by rule (Decider, reason "withdrew"). Without a decision the
    # participation stays undecided and Stages::Close refuses the whole stage for everyone else
    # (test engine F3). On an OPEN stage it is decided now; on a draft stage Stages::Open decides
    # it when the stage opens (no decision is allowed on a draft, D37); a closed stage is final.
    def decide_withdrawal_on_open_stages
      @application.participations.includes(:stage).each do |participation|
        next unless participation.stage.status == "open"

        participation.update!(attendance: "withdrew")
        current = participation.current_decision
        next if current && current.reason_code == "withdrew"

        result = Scoring::Decider.decide(score: nil, threshold: participation.stage.threshold, attendance: :withdrew)
        Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s,
                         reason_code: result.reason_code, decided_at: @now, supersedes: current,
                         note: current && "Applicant withdrew consent to the use of their data")
      end
    end

    def own_appointment(id)
      Appointment.joins(:participation).find_by(id:, participations: { job_application_id: @application.id }) ||
        refuse!("Appointment not found.")
    end

    def refuse!(message) = raise(Refused, message)
  end
end
