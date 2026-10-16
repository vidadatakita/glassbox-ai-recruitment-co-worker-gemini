module Portal
  # The portal's items in screen 6 Antrean Kerja, oldest first. No deadline is invented for
  # objections or the offer-to-start follow-up (no number decided, feature record §8).
  class WorkQueue
    # jobs: the jobs the viewer may see (Job.visible_to); unmatched link requests (no job) only when
    # the viewer is DataKita staff (no client company).
    def initialize(jobs:, unassigned: false, now: Time.current)
      @jobs = jobs
      @unassigned = unassigned
      @now = now
    end

    def reschedule_requests = appointments.where(confirmation: "reschedule_requested").order(:updated_at)

    # Not confirmed and starting within the next 24 hours (feature plan §4, screen 6).
    def unconfirmed_soon
      appointments.where(confirmation: "pending", starts_at: @now..(@now + 24.hours)).order(:starts_at)
    end

    def objections = Objection.open.joins(participation: :stage).where(stages: { job_id: @jobs }).includes(participation: [:stage, { job_application: :candidate }]).order(:received_at)
    # The 20 latest answers, newest first: an information list, not a task, so no window is decided.
    def offer_responses = offers.where.not(response: nil).order(responded_at: :desc).limit(20)
    def follow_ups = offers.where(response: "accepted", followed_up_at: nil).order(:start_at)
    def link_requests
      open = LinkRequest.where(handled_at: nil)
      (@unassigned ? open.where(job_id: @jobs).or(open.where(job_id: nil)) : open.where(job_id: @jobs)).order(:created_at)
    end

    def mail_failures = MailDelivery.failed_open.joins(:job_application).where(job_applications: { job_id: @jobs }).includes(job_application: :candidate).order(:created_at)

    private

    def appointments = Appointment.joins(participation: :stage).where(stages: { job_id: @jobs }).includes(participation: [:stage, { job_application: :candidate }])
    def offers = OfferDocument.joins(:job_application).where(job_applications: { job_id: @jobs }).includes(job_application: :candidate)

    public

    def total
      [reschedule_requests, unconfirmed_soon, objections, follow_ups, link_requests, mail_failures].sum(&:count)
    end
  end
end
