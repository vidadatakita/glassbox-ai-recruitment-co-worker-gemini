module Staff
  # The discrimination test on the brief's requirements (Appendix D structure), on the brief page:
  # "Run the test" stores the verdicts; each flagged line is then decided by the HR owner or the
  # consultant (keep with a reason, use the neutral wording, delete). The brief cannot be completed
  # while a flagged line waits (Briefs::Complete). The test never changes a requirement by itself.
  class RequirementChecksController < BaseController
    before_action -> { require_role!(*JobBriefsController::EDITORS) }
    before_action :load_job

    def create
      lines = Briefs::RequirementCheck.run!(job: @job, actor: current_user)
      flagged = lines.count { |l| l["verdict"] != "keep" }
      notice = flagged.zero? ? "Discrimination test run: no requirement is flagged." : "Discrimination test run: #{flagged} #{'requirement'.pluralize(flagged)} flagged. Decide each line below; the brief completes only when none is open."
      redirect_to staff_job_brief_path(@job, anchor: "requirement-check"), notice:
    end

    def decide
      Briefs::RequirementCheck.decide!(job: @job, actor: current_user, line_id: params[:line_id], decision: params[:decision], note: params[:note])
      redirect_to staff_job_brief_path(@job, anchor: "requirement-check"), notice: "Decision recorded under your name."
    rescue Briefs::RequirementCheck::Refused => e
      redirect_to staff_job_brief_path(@job, anchor: "requirement-check"), alert: e.message
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])
  end
end
