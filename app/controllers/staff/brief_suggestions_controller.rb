module Staff
  # "Ask for AI advice" on brief steps 2-4 (Briefs::Suggest). The proposal only fills the form of
  # the step it was asked from (step 2's also fills step 3 after a step-2 save, ?saran=<id>);
  # nothing in the brief changes until the person presses Save.
  class BriefSuggestionsController < BaseController
    before_action -> { require_role!(*JobBriefsController::EDITORS) }

    def create
      job = org_jobs.find(params[:job_id])
      step = params[:step].in?(%w[3 4 5 ad]) ? params[:step] : "2"
      # Step 5 follows the test's own rule (the job's consultant edits, a new version after approval);
      # the ad, until HR approves it; steps 2-4 need a brief that can still change.
      allowed = case step
                when "5" then TestCases::Authority.may_edit?(current_user, job)
                when "ad" then job.ad_writable_by?(current_user)
                else JobBriefsController.suggestable?(job)
                end
      unless allowed
        refusal = { "5" => TestCases::Authority.edit_refusal(current_user, job), "ad" => "The job ad is live and only the HR Admin can change it." }
        return redirect_to(back_to(job, step), alert: refusal.fetch(step, "AI advice is only for a brief that is not locked and has no applications yet."))
      end

      result = Briefs::Suggest.call(job:, actor: current_user, step:, instruction: params[:instruksi], draft: (params[:ad_text] if step == "ad"))
      return redirect_to(back_to(job, step), alert: result.error) unless result.ok?

      redirect_to back_to(job, step, saran: result.suggestion.id, anchor: "hasil-ai"),
                  notice: "AI advice loaded into the form. Check and edit as needed, then press Save; nothing is saved yet."
    end

    private

    def back_to(job, step, **query)
      case step
      when "5" then staff_job_test_case_step_path(job, **query)
      when "ad" then staff_job_ad_path(job, **query)
      else staff_job_brief_step_path(job, step, **query)
      end
    end
  end
end
