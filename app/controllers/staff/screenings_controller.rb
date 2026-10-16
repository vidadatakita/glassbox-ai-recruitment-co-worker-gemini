module Staff
  # Feature 06, S1 AI screening screens (blueprint §3.1 screen 8 "Screening review", §4.1 steps
  # 7-8, §4.3). Every rule lives in app/services/screening/*; this controller only checks the role
  # for the screen, calls the service, and says what happened.
  #
  # Roles (blueprint §1.2):
  #   start          consultant (runs the job)
  #   review         reviewer only (screen 8); create_review: reviewer, never the job's consultant
  #   calibration    consultant judges; reviewer may read (§1.2 "take part in calibration")
  #   cv_text        consultant pastes the text of an unreadable CV (§4.3)
  class ScreeningsController < BaseController
    before_action :load_job, only: %i[start review calibration]
    before_action -> { require_role!(:consultant) }, only: %i[start judge cv_text save_cv_text]
    before_action -> { require_role!(:reviewer) }, only: %i[review create_review]
    before_action -> { require_role!(:consultant, :reviewer) }, only: :calibration

    def start
      unless Screening::Config.enabled?
        return redirect_to(staff_job_path(@job), alert: ScreeningBoard::OFF_MESSAGE)
      end

      counts = Screening::Start.call(@job)
      redirect_to staff_job_path(@job, anchor: "screening"),
                  notice: "#{counts[:queued]} application(s) queued for screening. #{counts[:decided]} pass decision(s) recorded."
    end

    def review
      @board = ScreeningBoard.new(@job)
      @consultant_blocked = @job.consultant_id.present? && @job.consultant_id == current_user.id
    end

    def create_review
      result = org_find(ScreeningResult, params[:id])
      job = result.participation.stage.job
      Screening::Review.call(result:, reviewer: current_user, verdict: params[:verdict], note: params[:note])
      redirect_to staff_job_screening_review_path(job), notice: "Review saved and the decision recorded."
    rescue Screening::Review::Refused => e
      redirect_to staff_job_screening_review_path(job), alert: e.message
    end

    def calibration
      @board = ScreeningBoard.new(@job)
    end

    def judge
      participation = org_find(Participation, params[:participation_id])
      job = participation.stage.job
      Screening::JudgeCalibration.call(participation:, user: current_user, outcome: params[:outcome], note: params[:note])
      redirect_to staff_job_screening_calibration_path(job, anchor: "kalibrasi-#{participation.id}"),
                  notice: "Calibration judgement saved."
    rescue Screening::JudgeCalibration::Refused => e
      redirect_to staff_job_screening_calibration_path(job), alert: e.message
    end

    def cv_text
      @participation = org_find(Participation, params[:participation_id])
    end

    def save_cv_text
      participation = org_find(Participation, params[:participation_id])
      Screening::PasteCvText.call(participation:, user: current_user, text: params[:cv_text])
      redirect_to staff_job_path(participation.stage.job, anchor: "screening"),
                  notice: "CV text saved. The application is queued for screening again."
    rescue Screening::PasteCvText::Refused => e
      @participation = participation
      flash.now[:alert] = e.message
      render :cv_text, status: :unprocessable_entity
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])
  end
end
