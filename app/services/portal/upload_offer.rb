module Portal
  # Stores a new offer version for an application (E24, D33). Refused unless the job's last
  # scored stage is closed and this application passed it ("after Interview 2", D28), and once
  # an offer has been accepted. A new version makes the older one's buttons stop working.
  class UploadOffer
    class Refused < StandardError; end

    def self.call(application:, actor:, params:, now: Time.current)
      new(application:, actor:, params:, now:).call
    end

    def initialize(application:, actor:, params:, now:)
      @application = application
      @actor = actor
      @params = params
      @now = now
    end

    def call
      # Pasal 40: after a consent withdrawal the person's data is no longer processed; an offer with
      # a salary and a start date is processing (test engine F8).
      refuse!("The applicant has withdrawn consent to the use of their data.") if @application.consent_withdrawn_at
      refuse!("The applicant has not passed the last closed stage.") unless passed_last_stage?
      refuse!("The applicant has already accepted the offer; a new version cannot be uploaded.") if @application.offer_documents.exists?(response: "accepted")
      pdf = @params[:pdf]
      refuse!("Upload the offer letter as a PDF.") unless pdf.respond_to?(:read) && pdf_bytes?(pdf)
      start_at = @params[:start_at].presence && Time.zone.parse(@params[:start_at])
      valid_until = @params[:valid_until].presence && Date.parse(@params[:valid_until])
      refuse!("Fill in the start date and the reply-by date.") if start_at.nil? || valid_until.nil?
      refuse!("The reply-by date must be today or later.") if valid_until < @now.in_time_zone.to_date
      refuse!("Fill in the first-day preparation.") if @params[:day_one_notes].to_s.strip.empty?

      OfferDocument.transaction do
        version = (@application.offer_documents.maximum(:version) || 0) + 1
        offer = @application.offer_documents.create!(version:, start_at:, valid_until:,
                                                      day_one_notes: @params[:day_one_notes].strip,
                                                      uploaded_by_id: @actor.id)
        offer.pdf.attach(pdf)
        offer
      end
    rescue Date::Error, ArgumentError
      refuse!("The date could not be read.")
    end

    private

    def passed_last_stage?
      # AI Builder Cup step 06: the HR owner's Continue at the last stage is final, like a closed stage.
      return true if Progression::Salary.ready?(@application)

      last = @application.job.stages.where.not(code: "RC").order(:code).last
      return false if last.nil? || last.status != "closed"

      participation = @application.participations.find_by(stage: last)
      participation&.current_decision&.outcome == "pass"
    end

    def pdf_bytes?(file)
      head = file.read(5)
      file.rewind
      head == "%PDF-"
    end

    def refuse!(message) = raise(Refused, message)
  end
end
