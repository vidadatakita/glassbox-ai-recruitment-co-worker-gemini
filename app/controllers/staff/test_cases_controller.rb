module Staff
  # Brief step 5 "Technical test" (D60 slice 2, plan §c): the job's technical test, versioned.
  # Every staff role reads it; the consultant saves (TestCases::SaveVersion decides: edit the
  # draft in place, or create version n + 1 with a reason); HR PIC approves a version
  # (TestCases::Approve). The case file is downloaded only through #case_file, as an attachment
  # with nosniff, never through a public ActiveStorage URL (plan §d).
  class TestCasesController < BaseController
    before_action :load_job
    before_action :require_test!
    before_action -> { require_role!(:consultant) }, only: :save
    before_action -> { require_role!(:hr_pic) }, only: :approve

    # ?saran=<id>: the form shows that AI proposal (Briefs::Suggest, step 5) instead of the saved version.
    def edit
      @suggestion = @job.brief_suggestions.find(params[:saran]) if params[:saran].present?
      render_step
    end

    def save
      result = TestCases::SaveVersion.call(job: @job, actor: current_user, params: test_case_params)
      return redirect_to(staff_job_test_case_step_path(@job), notice: saved_notice(result.test_case)) if result.ok?

      render_step(errors: result.errors, status: :unprocessable_content)
    end

    def approve
      test_case = @job.test_cases.find(params[:id])
      result = TestCases::Approve.call(test_case:, actor: current_user, seen_digest: params[:content_digest].to_s)
      if result.ok?
        redirect_to staff_job_test_case_step_path(@job),
                    notice: "Version #{test_case.version} approved. Applicants take this version until a newer version is approved."
      else
        render_step(errors: result.errors, status: :unprocessable_content)
      end
    end

    # Plan §d: private storage, served as a download (never rendered in the browser), with the
    # sniffing guard, and only when the attachment is still the blob recorded on the version.
    def case_file
      test_case = @job.test_cases.find(params[:id])
      attachment = test_case.case_file
      unless attachment.attached? && attachment.blob_id == test_case.case_file_blob_id
        return redirect_to(staff_job_test_case_step_path(@job), alert: "The version #{test_case.version} case study file is not available.")
      end

      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data attachment.download, filename: download_name(test_case), type: attachment.content_type, disposition: "attachment"
    end

    private

    def load_job = @job = org_jobs.find(params[:job_id])

    # A package without S2 has no step 5: the address does not exist for it (404), exactly as an
    # unknown step number did before D60.
    def require_test!
      raise ActiveRecord::RecordNotFound, "job #{@job.id} has no technical test" unless TestCases::Requirement.applies?(@job)
    end

    def render_step(errors: [], status: :ok)
      @errors = errors
      @versions = @job.test_cases.includes(:created_by, :approved_by, :criteria, case_file_attachment: :blob).to_a
      @current = @versions.select(&:approved?).max_by(&:version)
      @latest = @versions.max_by(&:version)
      @form = TestCaseForm.new(@job, @latest, submitted: errors.any? ? test_case_params : @suggestion&.form_params("5", @job))
      @check = Briefs::BriefCheck.new(@job)
      render :edit, status:
    end

    def saved_notice(test_case)
      "Technical test version #{test_case.version} saved as a draft. HR must approve it before applicants use it."
    end

    def download_name(test_case)
      "case-file-#{@job.id}-v#{test_case.version}.#{test_case.case_file_kind}"
    end

    def test_case_params
      return {} unless params.key?(:test_case)

      params.require(:test_case).permit(:instructions, :time_limit_minutes, :new_version_reason, :case_file,
                                        :answer_types_submitted, answer_types: [],
                                        criteria: %i[activity_id name weight anchor_1 anchor_3 anchor_5]).to_h
    end
  end
end
