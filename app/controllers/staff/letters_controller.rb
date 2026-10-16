module Staff
  # AI Builder Cup step 09 on the applicant page: the HR PIC asks the AI for a draft of the
  # rejection notice or the offer letter, edits it, and sends it. Rules in Progression::Letters.
  class LettersController < BaseController
    before_action -> { require_role!(:hr_pic) }
    before_action { @application = org_find(JobApplication, params[:application_id]) }

    # From the page's script (ai_fill.js, JSON) the draft fills the subject and body in place.
    def draft
      letter = Progression::Letters.draft(application: @application, actor: current_user, instruction: params[:instruksi])
      message = "The AI draft is ready. Check it and edit as needed before sending."
      return render(json: { ok: true, fields: { subject: letter.subject, body: letter.body }, message: }) if request.format.json?

      back notice: message
    rescue Progression::Letters::Refused => e
      return render(json: { ok: false, message: e.message }, status: :unprocessable_content) if request.format.json?

      back alert: e.message
    end

    def deliver
      Progression::Letters.send!(application: @application, actor: current_user, subject: params[:subject], body: params[:body])
      back notice: "Letter sent to the candidate's email."
    rescue Progression::Letters::Refused => e
      flash[:letter_subject] = params[:subject]
      flash[:letter_body] = params[:body]
      back alert: e.message
    end

    private

    def back(**flash_args) = redirect_to(staff_application_path(@application, anchor: "letter"), **flash_args)
  end
end
