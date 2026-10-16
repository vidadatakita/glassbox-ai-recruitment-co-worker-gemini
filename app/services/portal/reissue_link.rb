module Portal
  # "Request a new link" (D36). The candidate gives the job code and their email. If exactly one
  # live application matches, every older status link is revoked and a new one is emailed to the
  # address on file, never to an address typed into the form. Otherwise a request goes to the
  # work queue. The page answers the same in both cases, so it cannot be used to learn who applied.
  class ReissueLink
    def self.call(job_code:, email:, now: Time.current, mailer: CandidateMailer)
      # Returns :sent or :queued for tests and logs; the page shows the same text for both.
      email = email.to_s.strip.downcase
      application = JobApplication.joins(:job, :candidate)
                                  .where(jobs: { public_code: job_code.to_s.strip }, candidates: { email: })
                                  .where(consent_withdrawn_at: nil)
                                  .order(:id).last
      if application.nil?
        code = job_code.to_s.strip.presence
        # The job of the code, when it exists, so only that company's queue shows the request.
        LinkRequest.create!(job_code: code, job: code && Job.find_by(public_code: code), contact: email.presence || "(blank)") if email.present?
        return :queued
      end

      # The old links die only AFTER the new one was sent. If sending fails, the new link is
      # revoked and the old ones keep working, so a mail outage never leaves a candidate with no
      # working link (test engine F1: revoke-then-send left them with none, and no record).
      new_link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
      delivery = MailDelivery.deliver!(application, "status_link") { mailer.status_link(application, token) }
      if delivery.sent?
        OneTimeLink.where(subject: application, revoked_at: nil).where.not(id: new_link.id)
                   .update_all(revoked_at: now, updated_at: now)
      else
        new_link.revoke!(now)
      end
      :sent
    end
  end
end
