# Screen 11 Application status and its parts 11a–11d (BP §3.6 B2–B6; D33, D36). Everything is
# reached through the private token; a tampered, unknown, revoked or withdrawn link gets one
# "This link is not valid" page.
class CandidateStatusController < CandidateController
  # Sending a code is limited too: each press used to mail another live code, which multiplied a
  # forwarded link's guessing odds and could flood the inbox (test engine F9).
  # Both limits are counted per status link (by:), not per IP address: on Indonesian mobile data many
  # candidates share one carrier address, so a per-IP counter let one candidate block the others
  # (test engine G3). Each limit has its own name, so they no longer share one counter (G2).
  rate_limit to: 3, within: 10.minutes, only: :send_offer_code, name: "offer-code-send",
             by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_path(params[:token], anchor: "penawaran"), alert: "The code has been sent several times. Check your e-mail or try again in a few minutes." }
  rate_limit to: 5, within: 10.minutes, only: :unlock_offer, name: "offer-code-unlock",
             by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_path(params[:token], anchor: "penawaran"), alert: "Too many attempts. Try again in a few minutes." }

  before_action :load_link
  before_action :refuse_after_withdrawal, except: :show

  def show
    LinkOpen.create!(one_time_link: @link, opened_at: Time.current) if request.get?
    # D60 plan §a.2: a technical test past its deadline is recorded as a no-show before the page is
    # built, so the page and the record agree even when the recurring job has not run.
    TechnicalTests::Expire.call(@application)
    @status = CandidateStatus.new(@application.reload)
    @offer_unlocked = offer_unlocked?
  end

  def confirm_appointment
    actions.confirm_appointment!(params[:appointment_id])
    back notice: "Thank you. Your attendance has been recorded."
  end

  def reschedule
    actions.request_reschedule!(params[:appointment_id], params[:reason])
    back notice: "We have received your request for another time. We will contact you."
  end

  def object
    actions.object!(params[:participation_id], params[:text])
    back notice: "We have received your objection. Our staff will review it."
  end

  # D40: one confirmation step before a withdrawal; no code needed (withdrawal is a right and
  # must stay easy, Pasal 40).
  def confirm_withdraw
    @status = CandidateStatus.new(@application)
  end

  def withdraw
    actions.withdraw_consent!
    render "candidate_status/withdrawn"
  end

  # D36: the offer tab needs a one-time code sent to the email on file.
  def send_offer_code
    _record, code = OfferAccessCode.issue!(@application)
    delivery = MailDelivery.deliver!(@application, "offer_code") { CandidateMailer.offer_code(@application, code) }
    if delivery.sent?
      back anchor: "penawaran", notice: "The code has been sent to your e-mail."
    else
      back anchor: "penawaran", alert: "The e-mail could not be sent. Please try again in a moment."
    end
  end

  def unlock_offer
    if OfferAccessCode.redeem(@application, params[:code])
      session[offer_session_key] = (Time.current + OfferAccessCode::CODE_LIFETIME).to_i
      back anchor: "penawaran"
    else
      back anchor: "penawaran", alert: "The code does not match or has expired."
    end
  end

  def respond_offer
    return back(anchor: "penawaran", alert: "Enter the code from the e-mail first.") unless offer_unlocked?

    offer = actions.respond_to_offer!(params[:offer_id], response: params[:response], reason: params[:reason])
    notice = offer.accepted? ? "Thank you. Your acceptance has been recorded." : "Your answer has been recorded."
    back anchor: "penawaran", notice:
  end

  def offer_pdf
    return back(anchor: "penawaran", alert: "Enter the code from the e-mail first.") unless offer_unlocked?

    offer = @application.offer_documents.find_by(id: params[:offer_id])
    return render_invalid_link unless offer&.pdf&.attached?

    send_data offer.pdf.download, filename: "job-offer-v#{offer.version}.pdf",
                                  type: "application/pdf", disposition: "inline"
  end

  rescue_from Portal::CandidateActions::Refused do |error|
    back alert: error.message
  end

  private

  def load_link
    @link = OneTimeLink.live("candidate_status", params[:token])
    @application = @link&.subject
    render_invalid_link if @application.nil?
  end

  def refuse_after_withdrawal
    render_invalid_link if @application.consent_withdrawn_at.present?
  end

  def actions = Portal::CandidateActions.new(@application)
  def offer_session_key = "offer_unlocked_#{@application.id}"
  def offer_unlocked? = session[offer_session_key].to_i > Time.current.to_i

  def back(anchor: nil, **flash_options)
    redirect_to candidate_status_path(params[:token], anchor:), **flash_options
  end
end
