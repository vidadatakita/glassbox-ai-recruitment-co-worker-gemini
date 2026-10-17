module Staff
  # The fairness check screen (FLOW v2.1 "Checks on top of the flow"; build item C2). Computed on
  # demand, nothing stored: `show` prepares the variants without any model call (the redacted texts
  # and whether identical bytes would reach the model); `create` runs the check on the screening
  # client and renders the per-requirement table beside it. Every rule lives in
  # Screening::FairnessCheck; this controller checks the role, the brief, the credentials, and says
  # what happened in plain words.
  #
  # Who: the HR owner, the consultant and the reviewer. Not the owner (no candidate data is
  # involved, but the screen explains redaction internals that belong to the people running the
  # process) and not the admin.
  class FairnessChecksController < BaseController
    VIEWERS = %i[hr_admin hr_manager superadmin].freeze

    before_action -> { require_role!(*VIEWERS) }
    before_action :load_job
    before_action :require_complete_brief

    def show
      @variants = Screening::FairnessCheck.prepare(job: @job)
      @result = nil
    end

    def create
      unless Screening::Config.enabled?
        return redirect_to staff_job_fairness_check_path(@job), alert: "AI screening is off. No credentials are configured."
      end

      @variants = Screening::FairnessCheck.prepare(job: @job)
      @result = Screening::FairnessCheck.call(job: @job)
      render :show
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])

    # The check uses the vacancy's rubric; without a complete brief there is nothing to score against.
    def require_complete_brief
      return if @job.brief_complete? && Screening::Rubric.for(@job).problems.empty?

      redirect_to staff_job_path(@job), alert: "The vacancy brief is not complete yet. Complete it before running the fairness check."
    end
  end
end
