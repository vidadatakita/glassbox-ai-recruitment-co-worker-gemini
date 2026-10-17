module Staff
  # Competency test scoring (slice C, 17 Oct 2026): the HR Manager sees every three-step applicant of a
  # vacancy with the provisional score and the vacancy average, confirms the written answers of
  # applicants at or above the average, and records the AI-based result for those below it (Vida's
  # rule). Every rule lives in ApplicationDrafts::RecordScore and ::Board; this controller checks the
  # role for the screen and says what happened. HR Admins read the board; only HR Managers record.
  class BankScoringsController < BaseController
    before_action :load_job
    before_action -> { require_role!(:hr_manager, :hr_admin) }, only: :index
    before_action -> { require_role!(:hr_manager) }, only: %i[record retry_ai]

    def index
      @board = ApplicationDrafts::Board.new(@job)
      @can_score = can_score?
    end

    def record
      draft = ApplicationDraft.where(job_id: @job.id).where.not(submitted_at: nil).find(params[:id])
      ApplicationDrafts::RecordScore.call(draft:, reviewer: current_user, mode: params[:mode], ratings: params.fetch(:ratings, {}).permit!.to_h,
                                          note: params[:note])
      redirect_to staff_job_bank_scorings_path(@job), notice: "Competency test result recorded for #{label(draft)}."
    rescue ApplicationDrafts::RecordScore::Refused => e
      @board = ApplicationDrafts::Board.new(@job)
      @can_score = can_score? # the refusal page shows the controls only to someone who may use them (F6)
      @errors = [e.message]
      render :index, status: :unprocessable_content
    end

    # A failed AI run, or one stuck at "pending" (ApplicationDraft#ai_retryable?), can be run again
    # from the board.
    def retry_ai
      draft = ApplicationDraft.where(job_id: @job.id).where.not(submitted_at: nil).find(params[:id])
      return redirect_to(staff_job_bank_scorings_path(@job), alert: "Only a failed or stalled AI run can be retried, by an HR Manager who is not the consultant.") unless can_score? && draft.ai_retryable?

      draft.update_columns(ai_status: "pending", ai_error: nil, updated_at: Time.current)
      BankAnswerAiRateJob.perform_later(draft.id)
      redirect_to staff_job_bank_scorings_path(@job), notice: "AI suggestions requested again for #{label(draft)}."
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])
    def can_score? = current_user.role.in?(%w[hr_manager superadmin]) && @job.consultant_id != current_user.id
    def label(draft) = helpers.candidate_label(draft.job_application)
  end
end
