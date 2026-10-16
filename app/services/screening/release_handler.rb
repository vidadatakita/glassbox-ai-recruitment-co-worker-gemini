module Screening
  # What a release decision means for a CV (payload kind cv_screening, D51 B, feature 09). Called
  # by AiReleases::Release and AiReleases::Decline inside their transaction.
  module ReleaseHandler
    module_function

    # Refuses a release that could not be sent now: no API key (the screen says so), a gate that
    # closed while the text waited (consent or application withdrawn, decided by hand, stage
    # closed), or a text prepared from an older rubric or CV text (a new version is prepared).
    def releasable!(release)
      participation = release.participation
      raise AiReleases::Refused, ScreeningBoard::OFF_MESSAGE + " The text keeps waiting here." unless Config.enabled?
      raise AiReleases::Refused, "This application is no longer awaiting review." unless participation.screening_state == "awaiting_release"

      if (reason = Enqueue.blocked_reason(participation))
        participation.update!(screening_state: nil, screening_state_at: Time.current)
        raise AiReleases::Refused, "This application can no longer be screened (#{reason}). Nothing was sent."
      end
      application = participation.job_application
      fresh = release.rubric_digest == Rubric.for(release.job).digest && release.source_sha256 == AiRelease.digest(application.cv_text)
      return if fresh

      requeue(participation)
      raise AiReleases::Refused, "The vacancy brief or the CV text changed since this text was prepared. A new text is being prepared for review."
    end

    # The release has produced its stored result; it is never sent again (AiClient#send_released).
    def consumed?(release) = ScreeningResult.exists?(ai_release_id: release.id)

    # Released: back to the queue (inside the release transaction); the job is enqueued only after
    # the commit (#after_commit_release), so it never runs before the release row is visible.
    # The job finds the released text and sends exactly that.
    def after_release(release)
      release.participation.update!(screening_state: "queued", screening_failure: nil, screening_failure_detail: nil,
                                    screening_state_at: Time.current)
    end

    def after_commit_release(release) = ScreenParticipationJob.perform_later(release.participation_id)

    def after_decline(release)
      release.participation.update!(screening_state: "not_sent", screening_failure: nil, screening_failure_detail: nil,
                                    screening_state_at: Time.current)
    end

    def requeue(participation)
      participation.update!(screening_state: "queued", screening_failure: nil, screening_failure_detail: nil,
                            screening_state_at: Time.current)
      ScreenParticipationJob.perform_later(participation.id)
    end
  end
end
