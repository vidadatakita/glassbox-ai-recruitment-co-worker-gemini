module Staff
  # AI Builder Cup "before / after": the Impact summary over the user's own jobs (org_jobs), measured
  # from the records; the BEFORE figures are the client's own (Settings).
  class ImpactsController < BaseController
    before_action -> { require_role!(:hr_admin, :hr_manager, :superadmin) }

    def show
      @impact = Impact.new(org_jobs)
      # The same figures per vacancy, so each matrix row can link to the records behind it. Only
      # vacancies with applications: an empty one has no source to show.
      @by_job = org_jobs.joins(:job_applications).distinct.order(:id).map { |job| [job, Impact.new(Job.where(id: job.id))] }
      company = ClientCompany.find_by(id: Glassbox::Settings.settings_company_id(current_user)) || current_user.client_company
      @baseline = %w[baseline_hours_to_answer baseline_minutes_per_cv baseline_reasoned_pct].to_h { |k| [k, SystemSetting.value_of(k, company:)] }
    end
  end
end
