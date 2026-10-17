module Staff
  # Brief step 5 "Technical test" (D60 slice 2, plan §c): the job's technical test, versioned.
  # Every staff role reads it; the consultant saves (TestCases::SaveVersion decides: edit the
  # draft in place, or create version n + 1 with a reason); HR PIC approves a version
  # (TestCases::Approve). The case file is downloaded only through #case_file, as an attachment
  # with nosniff, never through a public ActiveStorage URL (plan §d).
  class TestCasesController < BaseController
    include TechnicalTestStep

    before_action :load_job
    before_action :require_test!
    before_action -> { require_role!(:hr_admin) }, only: %i[save ai_case]
    before_action -> { require_role!(:hr_admin) }, only: :approve

    # ?saran=<id>: the form shows that AI proposal (Briefs::Suggest, step 5) instead of the saved version.
    def edit
      @suggestion = @job.brief_suggestions.find(params[:saran]) if params[:saran].present?
      render_step
    end

    # AI co-worker (slice D): the case study text (Briefs::Suggest step 5) AND the case file
    # (TestCases::DraftCaseFile) in one press. Nothing is saved: the form opens filled, the file is
    # previewed and downloadable, and Save attaches it like an upload.
    def ai_case
      unless TestCases::Authority.may_edit?(current_user, @job)
        return redirect_to(staff_job_test_case_step_path(@job), alert: TestCases::Authority.edit_refusal(current_user, @job))
      end

      text = Briefs::Suggest.call(job: @job, actor: current_user, step: "5")
      return redirect_to(staff_job_test_case_step_path(@job), alert: text.error) unless text.ok?

      file = TestCases::DraftCaseFile.call(job: @job, actor: current_user, instructions: text.suggestion.test["instructions"])
      return redirect_to(staff_job_test_case_step_path(@job, saran: text.suggestion.id), alert: "The case study text is drafted below; the case file was not: #{file.error}") unless file.ok?

      redirect_to staff_job_test_case_step_path(@job, saran: text.suggestion.id, case_saran: file.suggestion.id, anchor: "ai-case-file"),
                  notice: "The AI drafted the case study and the case file. Check both, then Save."
    end

    # The proposed case file (applicant's sheets only), to check before saving.
    def ai_case_file
      proposal = case_file_proposals.find(params[:suggestion_id])
      response.headers["X-Content-Type-Options"] = "nosniff"
      instructions = @job.brief_suggestions.find_by(id: params[:saran])&.test&.dig("instructions")
      send_data TestCases::DraftCaseFile.workbook(proposal.payload.fetch("case_file"), instructions),
                filename: "case-file-draft-#{@job.id}.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", disposition: "attachment"
    end

    def save
      result = TestCases::SaveVersion.call(job: @job, actor: current_user, params: with_ai_case_file(test_case_params))
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

    # When the HR Admin saves the AI-drafted case without choosing another file, the drafted file is
    # built from the stored proposal and goes through SaveVersion exactly like an upload.
    def with_ai_case_file(attrs)
      return attrs if attrs[:case_file].present? || attrs["case_file"].present? || params[:case_saran].blank?

      proposal = case_file_proposals.find(params[:case_saran])
      bytes = TestCases::DraftCaseFile.workbook(proposal.payload.fetch("case_file"), attrs["instructions"] || attrs[:instructions])
      tempfile = Tempfile.new(["case-file", ".xlsx"], binmode: true).tap { |f| f.write(bytes); f.rewind }
      attrs.merge("case_file" => ActionDispatch::Http::UploadedFile.new(tempfile:, filename: "case-file-#{@job.id}.xlsx",
                                                                        type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
    end

    # Only this vacancy's AI case-file proposals: any other id (another vacancy's, or the case-study text
    # proposal) is not found (404), never a crash (independent test pass, slice D, F1/F2).
    def case_file_proposals = @job.brief_suggestions.where("payload ? 'case_file'")

    def saved_notice(test_case)
      "Technical test version #{test_case.version} saved as a draft. HR must approve it before applicants use it."
    end

    def download_name(test_case)
      "case-file-#{@job.id}-v#{test_case.version}.#{test_case.case_file_kind}"
    end
  end
end
