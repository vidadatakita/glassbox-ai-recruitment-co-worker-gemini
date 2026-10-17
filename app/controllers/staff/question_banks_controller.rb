module Staff
  # Brief step 5, competency test bank (FLOW §7, 17 Oct 2026). The HR Admin who edits the vacancy's
  # test builds the bank (settings, questions, AI draft) and submits it; the HR Manager approves it
  # or returns it with a reason. Every role may read it (the step page). Who may do what is decided
  # in TestCases::SaveBank / BankDecision (TestCases::Authority), so a direct POST is refused the same
  # way as a hidden button. Every success redirects to the bank on the step page; a refusal renders
  # the page with the errors beside the bank.
  class QuestionBanksController < BaseController
    include TechnicalTestStep

    before_action :load_job
    before_action :require_test!

    def settings = save_bank("settings", notice: "Question bank settings saved.")
    # "Write with AI" sends this form with ai=1: the AI writes ONE question for the chosen section, type
    # and brief row and the reply fills the form in place (JSON for ai_fill.js); nothing is saved.
    def add_question
      return write_with_ai if params[:ai].present?

      save_bank("add", notice: "Question added to the bank.")
    end
    def update_question = save_bank("update", notice: "Question saved.")
    def remove_question = save_bank("remove", notice: "Question removed from the bank.")

    def accept_ai
      suggestion = @job.brief_suggestions.find(params[:suggestion_id])
      save_bank("accept_ai", suggestion:, notice: "AI-drafted questions added. Read each one before submitting the bank.")
    end

    def ai_draft
      unless TestCases::Authority.may_edit_bank?(current_user, @job)
        return render_step(bank_errors: [TestCases::Authority.edit_refusal(current_user, @job)], status: :forbidden)
      end

      result = TestCases::DraftBank.call(job: @job, actor: current_user, bank: QuestionBank.latest_for(@job))
      return render_step(bank_errors: [result.error], status: :unprocessable_content) unless result.ok?

      redirect_to staff_job_test_case_step_path(@job, bank_saran: result.suggestion.id, anchor: "question-bank-ai"),
                  notice: "The AI drafted #{result.suggestion.payload.dig('bank', 'questions').size} questions. Tick the ones to add."
    end

    # The Excel template (empty) or the current bank as a workbook (filled), for import and round trip.
    def workbook
      bank = params[:filled].present? ? QuestionBank.latest_for(@job) : nil
      bytes = TestCases::BankWorkbook.export(@job, bank ? bank.questions.to_a : [])
      name = bank ? "question-bank-#{@job.id}-v#{bank.version}.xlsx" : "question-bank-template-#{@job.id}.xlsx"
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data bytes, filename: name, type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", disposition: "attachment"
    end

    def import
      result = TestCases::ImportBank.call(job: @job, actor: current_user, file: params[:file], reason: params[:new_version_reason])
      return render_step(bank_errors: result.errors, status: :unprocessable_content) unless result.ok?

      redirect_to staff_job_test_case_step_path(@job, anchor: "question-bank"),
                  notice: "#{result.added} questions imported from Excel. Read them before submitting the bank."
    end

    def decide
      bank = QuestionBank.where(job_id: @job.id).find(params[:id])
      result = TestCases::BankDecision.call(bank:, actor: current_user, action: params[:decision], reason: params[:reason],
                                            seen_digest: params[:decision] == "approve" ? params[:content_digest].to_s : nil)
      return render_step(bank_errors: result.errors, status: :unprocessable_content) unless result.ok?

      redirect_to staff_job_test_case_step_path(@job, anchor: "question-bank"), notice: DECISION_NOTICES.fetch(params[:decision])
    end

    DECISION_NOTICES = {
      "submit" => "Question bank submitted. The HR Manager approves it or returns it with a reason.",
      "withdraw" => "Question bank taken back to draft; you can change it again.",
      "return" => "Question bank returned to the HR Admin with your reason.",
      "approve" => "Question bank approved. It is final; a change needs a new version with a reason."
    }.freeze

    private

    def write_with_ai
      attrs = bank_params
      result = TestCases::DraftQuestion.call(job: @job, actor: current_user, section: attrs["section"], kind: attrs["kind"], link_id: attrs["link_id"])
      if request.format.json?
        return render(json: { ok: result.ok?, fields: result.fields || {},
                              message: result.ok? ? "The AI wrote a question below. Read and edit it, then press Add question." : result.error },
                      status: result.ok? ? :ok : :unprocessable_content)
      end
      return render_step(bank_errors: [result.error], status: :unprocessable_content) unless result.ok?

      @ai_question = result.fields
      render_step
    end

    def load_job = @job = org_jobs.find(params[:job_id])

    def save_bank(action, notice:, suggestion: nil)
      result = TestCases::SaveBank.call(job: @job, actor: current_user, action:, params: bank_params, question_id: params[:question_id],
                                        suggestion:)
      return render_step(bank_errors: result.errors, status: :unprocessable_content) unless result.ok?

      redirect_to staff_job_test_case_step_path(@job, anchor: "question-bank"), notice:
    end

    def bank_params
      return {} unless params.key?(:bank)

      params.require(:bank).permit(:technical_draw, :role_draw, :time_limit_minutes, :new_version_reason, :section, :kind, :link_id,
                                   :prompt, :correct, :anchor_1, :anchor_3, :anchor_5, options: {}, picks: []).to_h
    end
  end
end
