module Staff
  # The job ad (AI Builder Cup step 02): the text candidates read on the apply page. The HR Admin and
  # the superadmin write it (or start from the AI's proposal, ?saran=<id>); every save is checked
  # for discriminatory wording (Briefs::AdCheck) and recorded. Since 17 Oct 2026 there is no separate
  # approval: a draft ad's save goes straight to the vacancy page's portal card, and opening the
  # portal shows the ad to applicants (Portal::WindowChange#open! records the approval).
  class JobAdsController < BaseController
    before_action -> { require_role!(:hr_admin, :hr_manager, :superadmin) }, only: :edit
    before_action -> { require_role!(*JobBriefsController::EDITORS) }, only: :update
    before_action :load_job

    def edit
      @suggestion = @job.brief_suggestions.find(params[:saran]) if params[:saran].present?
      @text = @suggestion ? @suggestion.ad_text : @job.ad_text
    end

    # Two buttons, one form: ai=1 asks the AI to write (or rewrite the draft in the box, with the
    # optional instruction); otherwise the text is saved and checked.
    def update
      return write_with_ai if params[:ai].present?

      result = Briefs::SaveAd.call(job: @job, actor: current_user, text: params[:ad_text], confirmed: params[:confirmed] == "1",
                                   reason: params[:flags_reason])
      if result.needs_reason
        # A live ad's text that names a protected attribute: the page comes back with what HR typed,
        # the rule flags of that text and the reason field, nothing saved.
        @text = params[:ad_text].to_s
        @unsaved_flags = result.flags
        flash.now[:alert] = result.error
        return render(:edit, status: :unprocessable_content)
      end
      return redirect_to(staff_job_ad_path(@job), alert: result.error) unless result.ok?

      # A live ad stays on its page; a draft ad goes straight to "Open the applicant portal".
      return redirect_to(staff_job_ad_path(@job), notice: "Job ad saved and shown to applicants.") if @job.ad_approved_at.present?

      notice = result.flags.any? ? "Job ad saved. #{result.flags.size} #{'flag'.pluralize(result.flags.size)} to check before you open the portal." : "Job ad saved. No sentence was flagged. Open the applicant portal when ready."
      redirect_to staff_job_path(@job, anchor: "applicant-portal"), notice:
    end

    private

    # From the page's script (ai_fill.js, JSON) the text fills the field in place, no reload;
    # without it, the page reloads on the AI's text as before.
    def write_with_ai
      refusal = "An approved job ad can only be changed by HR." unless @job.ad_writable_by?(current_user)
      result = Briefs::Suggest.call(job: @job, actor: current_user, step: "ad", instruction: params[:instruksi], draft: params[:ad_text]) unless refusal
      error = refusal || (result.error unless result.ok?)
      if request.format.json?
        return render(json: { ok: false, message: error }, status: :unprocessable_content) if error

        return render(json: { ok: true, fields: { ad_text: result.suggestion.ad_text },
                              message: "The AI has finished writing. Check the text, edit as needed, then save." })
      end
      return redirect_to(staff_job_ad_path(@job), alert: error) if error

      # Land on the AI's text, not the top of the page.
      redirect_to staff_job_ad_path(@job, saran: result.suggestion.id, anchor: "hasil-ai"), notice: "The AI has finished writing. Check the text, edit as needed, then save."
    end

    def load_job = @job = org_jobs.find(params[:job_id])
  end
end
