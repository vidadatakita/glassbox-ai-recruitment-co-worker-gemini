module Staff
  # Screen 6 Work queue, the portal's part (feature plan §4): what needs a person today.
  class WorkQueuesController < BaseController
    # Screen 6 belongs to the consultant (slice plan §2). Marking an item handled removes it from
    # the only screen that shows it, so only the consultant may (test engine F11).
    before_action -> { require_role!(:consultant) }, only: %i[handle_link_request handle_mail_failure]
    def show
      @queue = Portal::WorkQueue.new(jobs: org_jobs, unassigned: current_user.client_company_id.nil?)
    end

    def handle_link_request
      org_find(LinkRequest, params[:id]).update!(handled_at: Time.current, handled_by_id: current_user.id)
      redirect_to staff_work_queue_path, notice: "Link request marked done."
    end

    def handle_mail_failure
      org_find(MailDelivery, params[:id]).mark_handled!(current_user)
      redirect_to staff_work_queue_path, notice: "Email failure marked as handled."
    end
  end
end
