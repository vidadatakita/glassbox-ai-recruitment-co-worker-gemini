module Staff
  # Answering an objection (E21). Answered by a consultant or reviewer; the answer is shown to
  # the candidate on their status page.
  class ObjectionsController < BaseController
    before_action -> { require_role!(:consultant, :reviewer) }

    def answer
      org_find(Objection.open, params[:id]).answer!(user: current_user, outcome: params[:outcome], answer: params[:answer])
      redirect_to staff_work_queue_path, notice: "Objection answer sent; it is shown on the applicant's status page."
    rescue Objection::Refused => e
      redirect_to staff_work_queue_path, alert: e.message
    end
  end
end
