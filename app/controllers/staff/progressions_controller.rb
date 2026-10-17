module Staff
  # AI Builder Cup step 06 on the applicant page: the HR Admin scores the interview, asks the AI for its
  # recommendation, and chooses Continue / Follow AI advice / Do not continue. Rules live in
  # app/services/progression/*; this controller checks the role, calls, and says what happened.
  # Every role may create an interviewer's link (Progression::INVITER_ROLES, 17 Oct 2026).
  class ProgressionsController < BaseController
    before_action -> { require_role!(:hr_admin) }, except: :invite
    before_action -> { require_role!(*Progression::INVITER_ROLES) }, only: :invite
    before_action :load_participation

    def interview
      Progression::ScoreInterview.call(participation: @participation, actor: current_user, attendance: params[:attendance],
                                       ratings: params[:ratings]&.to_unsafe_h || {}, note: params[:note])
      back notice: "Interview scoring saved."
    rescue Progression::ScoreInterview::Refused => e
      back alert: e.message
    end

    def manual_score
      Progression::ScoreManual.call(participation: @participation, actor: current_user, attendance: params[:attendance],
                                    value: params[:value], tested_on: params[:tested_on], note: params[:note])
      back notice: "#{CandidateStatus::STAGE_LABELS.fetch(@participation.stage.code)} score saved."
    rescue Progression::ScoreManual::Refused => e
      flash[:manual_score_value] = params[:value]
      back alert: e.message
    end

    def invite
      _invite, token = Progression::InviteInterviewer.call(participation: @participation, actor: current_user, name: params[:interviewer_name])
      flash[:interviewer_link] = interviewer_score_url(token)
      flash[:interviewer_name] = params[:interviewer_name].to_s.strip
      flash[:interviewer_for] = @participation.id
      back notice: "Scoring link created."
    rescue Progression::InviteInterviewer::Refused => e
      back alert: e.message
    end

    def recommend
      return back(alert: "AI advice is made for CV screening.") unless Progression.step?(@participation)
      return back(alert: "The AI feature is off. Choose Continue or Do not continue yourself.") unless Screening::Config.enabled?

      rec = Progression::Recommend.call(participation: @participation, actor: current_user)
      rec.ready? ? back(notice: "AI advice refreshed.") : back(alert: rec.problem)
    end

    def choose
      choice = Progression::Choose.call(participation: @participation, actor: current_user, choice: params[:choice],
                                        seen_recommendation_id: params[:recommendation_id], note: params[:note])
      back notice: choice.direction == "lanjut" ? "#{choice.label} recorded. The candidate enters the next stage." : "#{choice.label} recorded."
    rescue Progression::Choose::Refused => e
      flash[:progression_field] = e.field.to_s if e.field
      flash[:progression_note] = params[:note]
      back alert: e.message
    end

    private

    def load_participation
      @participation = org_find(Participation.includes(:stage, :job_application), params[:participation_id])
    end

    def back(**flash_args)
      redirect_to staff_application_path(@participation.job_application, anchor: "stage-#{@participation.id}"), **flash_args
    end
  end
end
