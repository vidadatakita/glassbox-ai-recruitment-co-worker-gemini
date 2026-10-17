module Staff
  # Feature 08 writes on the candidate detail page. Every rule lives in app/services/screening_report/*;
  # this controller checks the role for the action, calls the service, and says what happened.
  #   label               reviewer (never the job's consultant)      D62 h3/h4
  #   approve_narratives  the job's consultant                       D62 h2
  #   user_recommendation HR PIC, naming the hiring manager           D62 h6
  class ScreeningReportActionsController < BaseController
    before_action -> { require_role!(:hr_manager) }, only: :label
    before_action -> { require_role!(:hr_admin) }, only: :approve_narratives
    before_action -> { require_role!(:hr_admin) }, only: :user_recommendation
    before_action :load_row

    def label
      ScreeningReport::ConfirmLabel.call(participation: @row.s1, reviewer: current_user, label: params[:label],
                                         note: params[:note], last_role_golongan: params[:last_role_golongan])
      back notice: "Label saved."
    rescue ScreeningReport::ConfirmLabel::Refused => e
      # A missing note is shown at the note field, with what was chosen kept (not only at the top).
      flash[:label_field] = "note" if e.message.match?(/\bnote\b/i)
      flash[:label_value] = params[:label]
      flash[:label_note] = params[:note]
      back alert: e.message, anchor: "label-analisa"
    end

    def approve_narratives
      raise ActiveRecord::RecordNotFound if @row.result.nil?

      ScreeningReport::ApproveNarratives.call(result: @row.result, user: current_user, note: params[:note])
      back notice: "Narrative approved. The AI draft mark is removed."
    rescue ScreeningReport::ApproveNarratives::Refused => e
      back alert: e.message, anchor: "narasi"
    end

    def user_recommendation
      ScreeningReport::RecordUserRecommendation.call(application: @row.application, user: current_user, user_name: params[:user_name],
                                                     pick: params[:pick], note: params[:note])
      back notice: "Hiring manager's pick saved."
    rescue ScreeningReport::RecordUserRecommendation::Refused => e
      back alert: e.message, anchor: "hiring-manager-pick"
    end

    private

    def load_row
      @board = ScreeningReportBoard.new(org_jobs.find(params[:job_id]), current_user)
      @row = @board.applicable? && @board.row_for(params[:application_id]) or raise ActiveRecord::RecordNotFound
    end

    def back(anchor: nil, **flash)
      redirect_to staff_job_screening_report_candidate_path(@board.job, @row.application.id, anchor:), **flash
    end
  end
end
