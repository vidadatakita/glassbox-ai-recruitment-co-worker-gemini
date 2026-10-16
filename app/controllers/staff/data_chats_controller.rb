module Staff
  # "Ask AI", behind the chat button on every staff page (staff/shared/_data_chat, data_chat.js):
  # JSON only. show: the user's last questions; create: one question answered by DataChat (fixed
  # read-only functions). 20 questions per 10 minutes per user.
  class DataChatsController < BaseController
    before_action :allowed!
    rate_limit to: 20, within: 10.minutes, only: :create, by: -> { Current.user&.id },
               with: -> { render json: { status: "refused", answer: "Too many questions. Try again in a few minutes.", links: [] }, status: :too_many_requests }

    # Opened in the browser (a bookmark, a shared link): the staff home with the chat window open,
    # never raw JSON. The window itself asks for JSON.
    def show
      respond_to do |format|
        format.html { redirect_to staff_jobs_path(anchor: "tanya-data") }
        format.json do
          history = DataQuestion.where(user: current_user).order(id: :desc).limit(10).reverse
          render json: history.map { |q| DataChat.replay(current_user, q) }
        end
      end
    end

    def create
      return redirect_to(staff_jobs_path(anchor: "tanya-data")) unless request.format.json?

      result = DataChat.ask(user: current_user, question: params[:question])
      # The data the AI read stays on the server (audit); the user sees the answer, the applicant
      # table and links, never raw data.
      render json: { status: result.status, answer: result.answer, table: result.table, choices: result.choices,
                     links: result.links.map { |label, path| { label:, path: } } }
    end

    private

    def allowed!
      head :forbidden unless current_user.role.in?(DataChat::ROLES)
    end
  end
end
