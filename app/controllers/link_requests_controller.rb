# "Request a new link" (D36): revokes the old link and emails a new one, or queues a request.
class LinkRequestsController < CandidateController
  # Loose per IP on purpose (D41; Glassbox::Settings::RATE_LIMITS): carriers share IPs.
  rate_limit to: Glassbox::Settings::RATE_LIMITS[:link_request_per_ip][:to],
             within: Glassbox::Settings::RATE_LIMITS[:link_request_per_ip][:within].seconds,
             only: :create, name: "link-request-ip"

  def new; end

  def create
    Portal::ReissueLink.call(job_code: params[:job_code], email: params[:email])
    render :sent
  end
end
