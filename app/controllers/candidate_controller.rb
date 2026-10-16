# Base for link-only candidate pages (screens 10–11): no account, phone first, own layout.
class CandidateController < ApplicationController
  allow_unauthenticated_access
  layout "candidate"

  private

  def render_invalid_link
    render "candidate_status/invalid", status: :not_found
  end
end
