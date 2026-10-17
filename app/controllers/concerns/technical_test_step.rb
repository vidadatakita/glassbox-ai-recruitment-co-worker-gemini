# Brief step 5 "Technical test" is one page with two parts: the competency test bank (Staff::
# QuestionBanksController) and the uploaded case document (Staff::TestCasesController). Both render
# the same page, so a refused change shows its errors in place (only a validation failure renders;
# every success redirects). This builds what the page reads.
module TechnicalTestStep
  extend ActiveSupport::Concern

  private

  def render_step(errors: [], status: :ok, bank_errors: [])
    @errors = errors
    @bank_errors = bank_errors
    @versions = @job.test_cases.includes(:created_by, :approved_by, :criteria, case_file_attachment: :blob).to_a
    @current = @versions.select(&:approved?).max_by(&:version)
    @latest = @versions.max_by(&:version)
    @form = TestCaseForm.new(@job, @latest, submitted: errors.any? ? test_case_params : @suggestion&.form_params("5", @job))
    @bank = QuestionBank.latest_for(@job)
    @current_bank = QuestionBank.current_for(@job)
    @bank_proposal = @job.brief_suggestions.find_by(id: params[:bank_saran]) if params[:bank_saran].present?
    @case_proposal = @job.brief_suggestions.find_by(id: params[:case_saran]) if params[:case_saran].present?
    @check = Briefs::BriefCheck.new(@job)
    render "staff/test_cases/edit", status:
  end

  def test_case_params
    return {} unless params.key?(:test_case)

    params.require(:test_case).permit(:instructions, :time_limit_minutes, :new_version_reason, :case_file,
                                      :answer_types_submitted, answer_types: [],
                                      criteria: %i[activity_id name weight anchor_1 anchor_3 anchor_5]).to_h
  end

  # A package without S2 has no step 5: the address does not exist for it (404), exactly as an
  # unknown step number did before D60.
  def require_test!
    raise ActiveRecord::RecordNotFound, "job #{@job.id} has no technical test" unless TestCases::Requirement.applies?(@job)
  end
end
