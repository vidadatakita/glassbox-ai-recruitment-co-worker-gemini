module Staff
  # Offer upload (E24, D33): the consultant uploads the PDF; generating the letter is T2.
  # Allowed only after the job's last scored stage is closed with a pass for this application.
  class OffersController < BaseController
    before_action -> { require_role!(:consultant) }

    def create
      application = org_find(JobApplication, params[:application_id])
      Portal::UploadOffer.call(application:, actor: current_user, params: offer_params)
      redirect_to staff_application_path(application), notice: "Offer uploaded. The applicant can see it on the status page."
    rescue Portal::UploadOffer::Refused => e
      redirect_to staff_application_path(application), alert: e.message
    end

    # E22: the offer-to-start follow-up is done (a call or message before the start date).
    def followed_up
      offer = org_find(OfferDocument, params[:id])
      offer.update!(followed_up_at: Time.current, followed_up_by_id: current_user.id) if offer.accepted? && offer.followed_up_at.nil?
      redirect_to staff_work_queue_path, notice: "Follow-up before the first day recorded."
    end

    private

    def offer_params = params.require(:offer).permit(:pdf, :start_at, :valid_until, :day_one_notes)
  end
end
