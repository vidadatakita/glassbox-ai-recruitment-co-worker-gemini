module Staff
  # Buka / Tutup / Buka lagi on the Portal Pelamar box (BP §3.6 A). Roles are checked inside
  # Portal::WindowChange, which also logs the actor's role.
  class PortalWindowsController < BaseController
    before_action -> { @job = org_jobs.find(params[:job_id]) }

    def open
      Portal::WindowChange.open!(job: @job, actor: current_user, closes_at: closes_at_param, quota: quota_param)
      redirect_to staff_job_path(@job), notice: "Applicant portal opened."
    end

    def close
      Portal::WindowChange.close!(job: @job, actor: current_user, reason: params[:reason])
      redirect_to staff_job_path(@job), notice: "Applicant portal closed."
    end

    def reopen
      Portal::WindowChange.reopen!(job: @job, actor: current_user, reason: params[:reason],
                                   closes_at: closes_at_param, quota: quota_param)
      redirect_to staff_job_path(@job), notice: "Applicant portal reopened."
    end

    rescue_from Portal::WindowChange::Refused do |error|
      redirect_to staff_job_path(@job), alert: error.message
    end

    private

    # The field is typed in WIB (datetime-local has no zone); Time.zone is Asia/Jakarta, so
    # parsing in it stores the right UTC instant (blueprint §2.2 rule 8).
    def closes_at_param = params[:closes_at].presence && Time.zone.parse(params[:closes_at])
    def quota_param = params[:quota].presence && Integer(params[:quota], 10)
  end
end
