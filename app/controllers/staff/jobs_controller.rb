module Staff
  # Screens 3 (My vacancies) and 4 (Vacancy home with the Applicant portal box).
  class JobsController < BaseController
    before_action :load_job, only: %i[show approve_ad]
    before_action -> { require_role!(:hr_pic) }, only: :approve_ad

    def index
      @jobs = org_jobs.includes(:client_company).order(:id).to_a
      @windows = @jobs.to_h { |job| [job.id, ApplicationWindow.new(job)] }
    end

    def show
      @board = Portal::JobBoard.new(@job)
    end

    # Process card 4: HR PIC approves the ad before the portal can open. The ad editor is Plan 3.
    # Feature 03 (task part D): the ad of a job whose brief is not complete cannot be approved,
    # because the brief is what S1 screens against (blueprint §1.1 "everything downstream is
    # generated from the brief"). Jobs approved before the brief existed keep their approval.
    def approve_ad
      unless @job.brief_complete?
        return redirect_to(staff_job_path(@job), alert: "The job ad cannot be approved yet because the vacancy brief is incomplete. Complete the brief in step 4.")
      end

      # Nothing to approve until the ad has a text (AI Builder Cup step 02).
      if @job.ad_text.blank? && @job.ad_approved_at.nil?
        return redirect_to(staff_job_ad_path(@job), alert: "The job ad has not been written. Write it first, then approve.")
      end

      # AI Builder Cup step 02: a flagged ad (Briefs::AdCheck) is approved only with the tick.
      if Briefs::AdCheck.flagged?(@job.ad_flags) && params[:flags_checked] != "1"
        return redirect_to(staff_job_ad_path(@job), alert: "The job ad has flags that need checking. Check or change the sentences, then tick \"I have checked the flags above\" before approving.")
      end

      @job.update!(ad_approved_at: Time.current, ad_approved_by_id: current_user.id) if @job.ad_approved_at.nil?
      redirect_to staff_job_path(@job), notice: "Job ad approved. The Applicant portal can be opened."
    end

    private

    def load_job = @job = org_jobs.find(params[:id])
  end
end
