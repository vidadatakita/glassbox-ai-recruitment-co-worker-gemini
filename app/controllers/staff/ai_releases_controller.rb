module Staff
  # Feature 09, D51 B: "Review before AI". A reviewer reads EXACTLY the text the API call
  # will send (AiRelease#payload_text), with the residual-check findings and protected-word hints
  # marked inside the text, then releases it ("Send to Gemini"), cuts lines ("Delete ticked lines") or
  # declines ("Not sent — decide manually"). Every rule lives in AiReleases::* and
  # Screening::ReleaseHandler; this controller checks the role, calls the service, and says what
  # happened.
  #
  # Reviewer only, on every action including the read: the screen shows CV text, so HR PIC and
  # owner (client users) and consultants never open it (D51; security-access-pdp-id). A reviewer who
  # is the job's consultant may read but every action is refused (and refused again by the
  # database).
  class AiReleasesController < BaseController
    before_action -> { require_role!(:reviewer) }
    before_action :load_release, except: :index

    def index
      @job = org_jobs.find(params[:job_id])
      @board = ScreeningBoard.new(@job)
      @items = @board.awaiting_release.map { |p| [p, AiRelease.latest_for(p)] }.select { |(_, r)| r }
      @decided = AiReleaseAction.joins(:ai_release).where(ai_releases: { job_id: @job.id })
                                .includes(:actor, ai_release: { participation: :job_application }).order(id: :desc).limit(20)
      @measure = AiReleases::PilotMeasure.new(job: @job)
    end

    def show
      @job = @release.job
      @latest = AiRelease.latest_for(@release.participation, @release.payload_kind)
      @consultant_blocked = @job.consultant_id.present? && @job.consultant_id == current_user.id
    end

    def release
      AiReleases::Release.call(release: @release, user: current_user, confirmed: params[:confirmed], seen_sha256: params[:payload_sha256])
      redirect_to staff_job_ai_releases_path(@release.job), notice: "Text sent to the AI queue. The text sent is exactly the one you checked."
    rescue AiReleases::Refused => e
      redirect_to staff_ai_release_path(@release), alert: e.message
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      refused_by_database(e)
    end

    def cut
      fresh = AiReleases::Cut.call(release: @release, user: current_user, line_numbers: params[:lines])
      redirect_to staff_ai_release_path(fresh), notice: "The selected lines were deleted and recorded under your name. Check this new version of the text."
    rescue AiReleases::Refused => e
      redirect_to staff_ai_release_path(@release), alert: e.message
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      refused_by_database(e)
    end

    def decline
      AiReleases::Decline.call(release: @release, user: current_user, note: params[:note])
      redirect_to staff_job_ai_releases_path(@release.job), notice: "Text not sent to the AI. The decision for this stage is made manually."
    rescue AiReleases::Refused => e
      redirect_to staff_ai_release_path(@release), alert: e.message
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      refused_by_database(e)
    end

    private

    def load_release = @release = org_find(AiRelease, params[:id])

    # Two reviewers acting on the same version at once, or a guard the service missed: the database
    # refused. Shown on screen (never swallowed) and logged with the error class only, never the text.
    def refused_by_database(error)
      # Only the two expected refusals; any other database error is a defect and must surface.
      raise error unless error.is_a?(ActiveRecord::RecordNotUnique) || error.cause.is_a?(PG::CheckViolation)

      Rails.logger.warn("[ai_release] release=#{@release.id} refused by database: #{error.class.name}")
      redirect_to staff_ai_release_path(@release), alert: "Not saved: this text was already decided or changed by someone else. Reload the page."
    end
  end
end
