module Staff
  # Offer upload (E24, D33): the consultant uploads the PDF; generating the letter is T2.
  # Allowed only after the job's last scored stage is closed with a pass for this application.
  class OffersController < BaseController
    before_action -> { require_role!(:hr_admin) }

    def create
      application = org_find(JobApplication, params[:application_id])
      Portal::UploadOffer.call(application:, actor: current_user, params: offer_params)
      redirect_to staff_application_path(application), notice: "Offer uploaded. The applicant can see it on the status page."
    rescue Portal::UploadOffer::Refused => e
      redirect_to staff_application_path(application), alert: e.message
    end

    # AI advice (17 Oct 2026): Gemini drafts the "First-day preparation" note from the brief. From the
    # page script (ai_fill.js, JSON) the text fills the field in place; without it the page reloads with
    # the draft in the field (flash). Nothing is stored until the HR Admin uploads the offer.
    def advice
      application = org_find(JobApplication, params[:application_id])
      text = Progression::OfferAdvice.draft(application:, actor: current_user)
      message = "The AI drafted the first-day note from the brief. Check and edit it, then upload the offer."
      return render(json: { ok: true, fields: { "offer[day_one_notes]" => text }, message: }) if request.format.json?

      flash[:offer_day_one_draft] = text
      redirect_to staff_application_path(application, anchor: "job-offer"), notice: message
    rescue Progression::OfferAdvice::Refused => e
      return render(json: { ok: false, message: e.message }, status: :unprocessable_content) if request.format.json?

      redirect_to staff_application_path(application, anchor: "job-offer"), alert: e.message
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
