module Staff
  # Logged-in screens for HR and DataKita staff. Authentication comes from the Rails 8
  # generator (Authentication concern); roles follow blueprint §1.2. Tenant scoping of every
  # query is Plan 2 (this slice runs TENANCY=single, one company).
  class BaseController < ApplicationController
    layout "staff"
    # Staff use managed browsers; candidates do not, so this lives here, not in ApplicationController.
    allow_browser versions: :modern

    helper_method :current_user, :org_jobs

    private

    def current_user = Current.user

    # Every staff lookup is scoped to the user's organization (client company): see Job.visible_to.
    def org_jobs = Job.visible_to(current_user)

    # A record found by id whose job lies outside the user's organization answers 404, exactly like
    # a missing one, so ids of other companies cannot be probed. A record without a job (an
    # unmatched link request) is DataKita staff's only.
    def org_find(scope, id)
      record = scope.find(id)
      job = record.is_a?(Job) ? record : record.job
      allowed = job ? org_jobs.exists?(job.id) : current_user.client_company_id.nil?
      raise ActiveRecord::RecordNotFound unless allowed

      record
    end

    # The superadmin passes every role check (GlassBox Team, 17 Oct 2026).
    def require_role!(*roles)
      return if current_user.role == "superadmin" || roles.map(&:to_s).include?(current_user.role)

      redirect_to staff_jobs_path, alert: "You do not have access to this action."
    end
  end
end
