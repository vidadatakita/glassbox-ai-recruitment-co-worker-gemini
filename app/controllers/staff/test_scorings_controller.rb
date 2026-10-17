module Staff
  # "Technical test scoring" (D60 slice 5; plan §c, §d): the reviewer scores technical-test answers on
  # the pinned version's rubric. Every rule lives in TechnicalTests::ScoreAnswer; this controller
  # checks the role for the screen and says what happened.
  #
  # Names: every label goes through the shared CandidateIdentity rule (CandidateIdentityHelper,
  # D62 h7): client roles see "Kandidat NN" until the gate is closed.
  #
  # Roles (blueprint §1.2; D60 16:45; D62 h7):
  #   index        reviewer (scores), consultant (reads, never scores), hr_pic and owner (read,
  #                candidate numbers only, no answer download)
  #   create       reviewer, never the job's consultant
  #   answer_file  TechnicalTests.answer_downloadable_by?: reviewer and consultant always, HR PIC
  #                once the gate is closed (SPEC screening report §2.4, D62 h7), owner/admin never
  class TestScoringsController < BaseController
    before_action :load_job, only: :index
    before_action -> { require_role!(:hr_manager, :hr_admin) }, only: :index
    before_action -> { require_role!(:hr_manager) }, only: %i[create ai_preview ai_score]
    # The HR PIC is admitted here only so TechnicalTests.answer_downloadable_by? can decide (gate
    # closed); org_find below keeps every lookup inside the user's own company.
    before_action -> { require_role!(:hr_manager, :hr_admin) }, only: :answer_file

    def index
      raise ActiveRecord::RecordNotFound, "job #{@job.id} has no technical test gate" unless GateBoard.new(@job).applicable?

      # Plan §a.2: expiry is evaluated lazily here too, so the counts never show a dead test as waiting.
      @job.job_applications.find_each { |application| TechnicalTests::Expire.call(application) }
      @board = TestScoringBoard.new(@job)
      @consultant_blocked = @job.consultant_id.present? && @job.consultant_id == current_user.id
      @can_score = current_user.role.in?(%w[hr_manager superadmin]) && !@consultant_blocked && @board.stage.status == "open"
      # ?ai=<id>: the AI's proposal for one answer fills that answer's scoring form (reviewer confirms).
      @ai_suggestion = TestAiSuggestion.joins(test_attempt: { participation: :stage }).where(stages: { job_id: @job.id }).find_by(id: params[:ai]) if params[:ai].present?
    end

    # "Ask for AI advice", step 1: the exact text that would be sent, with the rubric. Nothing is sent.
    def ai_preview
      @attempt = org_find(TestAttempt, params[:id])
      @job = @attempt.participation.stage.job
      return redirect_to(staff_job_test_scorings_path(@job), alert: "Only a reviewer who is not the consultant of this vacancy can ask for AI advice.") unless TechnicalTests::AiScore.allowed?(current_user, @attempt)

      @answer = TechnicalTests::AnswerText.call(@attempt)
      @content = TechnicalTests::AiScore.content(@answer.text, @attempt.test_case) if @answer.ok?
    end

    # Step 2: the reviewer sends what they read (its digest is checked again); the proposal fills the form.
    def ai_score
      attempt = org_find(TestAttempt, params[:id])
      job = attempt.participation.stage.job
      suggestion = TechnicalTests::AiScore.call(attempt:, reviewer: current_user, seen_sha256: params[:sha256])
      redirect_to staff_job_test_scorings_path(job, ai: suggestion.id, anchor: "jawaban-#{attempt.id}"),
                  notice: "AI advice loaded into the scoring form. Check it, change it where needed, write a note, then save. A person decides every step."
    rescue TechnicalTests::AiScore::Refused => e
      redirect_to staff_job_test_scorings_path(job, anchor: "jawaban-#{attempt.id}"), alert: e.message
    end

    def create
      attempt = org_find(TestAttempt, params[:id])
      job = attempt.participation.stage.job
      TechnicalTests::ScoreAnswer.call(attempt:, reviewer: current_user, ratings: params.fetch(:ratings, {}).permit!.to_h,
                                       note: params[:note])
      redirect_to staff_job_test_scorings_path(job), notice: "Score saved and the technical test decision recorded."
    rescue TechnicalTests::ScoreAnswer::Refused => e
      redirect_to staff_job_test_scorings_path(job, anchor: "jawaban-#{attempt.id}"), alert: e.message
    end

    # Plan §d: private storage, a short-lived signed key bound to this user, served as a download
    # with nosniff, and only when the attachment is still the blob recorded with the answer.
    def answer_file
      attempt = org_find(TestAttempt, params[:id])
      job = attempt.participation.stage.job
      unless TechnicalTests.answer_downloadable_by?(current_user, job) && TechnicalTests.answer_key_valid?(params[:k], current_user, attempt) &&
             attempt.answer_file.attached? && attempt.answer_file.blob_id == attempt.answer_blob_id
        return redirect_to(staff_job_test_scorings_path(job), alert: "The answer download link is no longer valid. Reload this page.")
      end

      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data attempt.answer_file.download, filename: "jawaban-tes-#{job.id}-#{attempt.id}.#{attempt.answer_kind}",
                                              type: attempt.answer_file.content_type, disposition: "attachment"
    end

    private

    # Tenant scoping (multi-company): the job is looked up only among the user's own company's jobs.
    # The signed answer link is TestAnswerHelper#answer_link over TechnicalTests.answer_key.
    def load_job = @job = org_jobs.find(params[:job_id])
  end
end
