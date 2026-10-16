module Staff
  # Screen 2 "Buat Lowongan" (blueprint §3.1): a four-step wizard, each step saved as a draft with
  # "Save" and then the next step. D49 (5): HR PIC and consultant both fill in and edit; owner,
  # reviewer and admin see the brief read-only (show). Every save is recorded by Briefs::SaveStep.
  class JobBriefsController < BaseController
    EDITORS = %i[hr_pic consultant].freeze
    STEP_TITLES = JobBriefChange::STEP_LABELS.slice("1", "2", "3", "4").freeze

    before_action -> { require_role!(*EDITORS) }, except: :show
    before_action :load_job, except: %i[new create]

    # The AI may propose the brief (Briefs::Suggest) while the requirements and knockout questions
    # can still change: brief not locked and no application in yet.
    def self.suggestable?(job) = job.persisted? && !job.brief_locked? && !job.job_applications.exists?

    def new
      @job = Job.new
      render_step("1")
    end

    # Step 1 creates the job, for the creator's own client company; DataKita staff (no company)
    # pick it, a choice shown only when the install has more than one company.
    def create
      @job = Job.new(client_company: company_for_new_job)
      result = Briefs::SaveStep.call(job: @job, step: "1", params: brief_params, actor: current_user)
      return redirect_to(staff_job_brief_step_path(@job, 2), notice: "Vacancy saved as a draft. Continue with the activities.") if result.ok?

      render_step("1", errors: result.errors, status: :unprocessable_content)
    end

    def show
      @check = Briefs::BriefCheck.new(@job)
      @locked = @job.brief_locked?
    end

    # ?saran=<id> on steps 2-4: the form shows that AI proposal instead of the saved brief.
    def edit
      suggestion = @job.brief_suggestions.find(params[:saran]) if params[:saran].present? && params[:step].in?(%w[2 3 4])
      render_step(params[:step], suggestion:)
    end

    def update
      step = params[:step]
      result = Briefs::SaveStep.call(job: @job, step:, params: brief_params, actor: current_user)
      return render_step(step, errors: result.errors, status: :unprocessable_content) unless result.ok?
      return finish if step == "4" && params[:finish].present?
      # Step 4 of a package with the technical test: step 5 comes next, and completes the brief.
      return redirect_to(staff_job_test_case_step_path(@job), notice: "Draft saved. Continue with the technical test.") if step == "4" && params[:lanjut].present? && TestCases::Requirement.applies?(@job.reload)
      # Step 2 saved from an AI proposal: step 3 opens with the same proposal's requirements.
      return redirect_to(staff_job_brief_step_path(@job, 3, saran: params[:saran]), notice: "Draft saved. The requirements below are also AI advice; check them, then Save.") if step == "2" && params[:saran].present?

      redirect_to next_path(step), notice: "Draft saved."
    end

    # "Selesaikan brief" on step 5 (the last step when the package runs the technical test). Nothing
    # to save there; a refusal lists what is missing on the brief page, each with a link to its step.
    def complete
      result = Briefs::Complete.call(job: @job, actor: current_user)
      return redirect_to(staff_job_brief_path(@job), notice: "Brief completed. HR can approve the job ad.") if result.ok?

      redirect_to staff_job_brief_path(@job), alert: "The brief cannot be completed yet. Complete the parts marked below; each line links to its step."
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])

    # "Save & complete brief": the draft is already saved; completion is a separate check so
    # a refused completion keeps what was typed and lists what is missing, step by step.
    def finish
      result = Briefs::Complete.call(job: @job.reload, actor: current_user)
      return redirect_to(staff_job_brief_path(@job), notice: "Brief completed. HR can approve the job ad.") if result.ok?

      flash.now[:alert] = "Draft saved, but the brief cannot be completed yet. Complete the parts listed below."
      @finish_refused = true
      render_step("4", status: :unprocessable_content)
    end

    def next_path(step) = step == "4" ? staff_job_brief_step_path(@job, 4) : staff_job_brief_step_path(@job, step.to_i + 1)

    def render_step(step, errors: [], status: :ok, suggestion: nil)
      @step = step
      @suggestion = suggestion
      @checking = @finish_refused || params[:periksa].present?
      @errors = errors
      # A refused save rolled back in the database but may leave built rows and assigned values on
      # the in-memory job; the checks and headings must read what is SAVED. What was typed is shown
      # from the submitted params instead (BriefForm).
      @job.reload if errors.any? && @job.persisted?
      @locked = @job.persisted? && @job.brief_locked?
      @knockout_locked = @locked || (@job.persisted? && @job.job_applications.exists?)
      @form = BriefForm.new(@job, step, submitted: errors.any? ? brief_params : suggestion&.form_params(step, @job))
      @check = Briefs::BriefCheck.new(@job) if @job.persisted?
      render :edit, status:
    end

    # Slots of the repeating sections arrive as "0" => {...}; permit accepts that shape. The stage
    # plan is keyed by stage code, so it is permitted per code and filtered again by the service.
    def company_for_new_job
      return current_user.client_company if current_user.client_company
      return ClientCompany.first if ClientCompany.count == 1

      ClientCompany.find_by(id: params[:client_company_id])
    end
    helper_method def pick_company? = current_user.client_company_id.nil? && ClientCompany.count > 1

    def brief_params
      return {} unless params.key?(:brief)

      params.require(:brief).permit(
        :title, :golongan, :headcount, :employment_type, :confidential, :success_90d,
        :salary_min, :salary_max, :show_salary, :relocation, :work_arrangement, :package, :package_override_reason,
        placements: [],
        activities: %i[id description output share_percent],
        requirements: %i[id tier text cv_evidence weight knockout],
        competencies: %i[id name layer stage_code anchor_1 anchor_3 anchor_5 questions],
        stage_plan: Briefs::StagePlan::DEFAULT_WEIGHTS.keys.to_h { |code| [code, %i[weight threshold]] }
      ).to_h
    end
  end
end
