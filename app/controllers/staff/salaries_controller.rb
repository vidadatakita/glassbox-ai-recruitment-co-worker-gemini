module Staff
  # AI Builder Cup step 08 on the applicant page: the AI's band position (HR PIC or owner asks) and
  # the owner's agreed salary. Rules in Progression::Salary.
  class SalariesController < BaseController
    before_action -> { require_role!(:hr_admin, :hr_manager) }, only: :recommend
    before_action -> { require_role!(:hr_manager) }, only: :agree
    before_action { @application = org_find(JobApplication, params[:application_id]) }

    def recommend
      return back(alert: "The candidate has not passed the last stage yet.") unless Progression::Salary.ready?(@application)
      return back(alert: "The AI feature is off. Set the salary without AI advice.") unless Screening::Config.enabled?

      rec = Progression::Salary.recommend(application: @application, actor: current_user)
      rec.ready? ? back(notice: "Salary AI advice refreshed.") : back(alert: rec.problem)
    end

    def agree
      Progression::Salary.agree(application: @application, actor: current_user, amount: params[:amount], note: params[:note],
                                seen_recommendation_id: params[:recommendation_id])
      back notice: "Salary agreed and recorded under your name."
    rescue Progression::Salary::Refused => e
      flash[:salary_field] = e.field.to_s if e.field
      flash[:salary_amount] = params[:amount]
      flash[:salary_note] = params[:note]
      back alert: e.message
    end

    private

    def back(**flash_args) = redirect_to(staff_application_path(@application, anchor: "salary"), **flash_args)
  end
end
