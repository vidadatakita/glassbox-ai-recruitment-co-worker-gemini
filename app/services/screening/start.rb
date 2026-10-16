module Screening
  # Job page action "Mulai screening": offers every S1 participation of the job to the queue again,
  # including failed screenings and finished ones whose rubric changed since, then writes the
  # automatic decisions that have become allowed (Screening::Finalize). Used after the API key is
  # set (applications that arrived while the AI was off were never queued), after a rubric fix,
  # and to retry "Screening gagal" rows. Returns { queued: n, decided: n }.
  class Start
    # "Manual check needed": the CV was never sent, and a new attempt would stop at the same check. A
    # consultant pastes a corrected text instead (Screening::PasteCvText), so a retry leaves these.
    NEEDS_CV_TEXT = %w[personal_data too_little_text no_evidence_section].freeze

    def self.call(job)
      stage = job.stages.find_by(code: "S1", score_source: "ai")
      return { queued: 0, decided: 0 } if stage.nil?

      queued = stage.participations.includes(:job_application).count { |p| Enqueue.call(p, rerun: true) == :queued }
      decided = Finalize.call(job)
      # Finalize ran without error: clear the finalize-error flag left by an earlier run (F-14).
      # The stored results were never re-sent.
      stage.participations.where(screening_state: "done", screening_failure: "finalize")
           .update_all(screening_failure: nil, screening_failure_detail: nil)
      { queued:, decided: }
    end

    # "Retry failed screening", the HR owner's and the reviewer's action: the public demo opens no
    # consultant door, so a CV whose AI call failed stayed failed (end-to-end test, 16 Oct 2026).
    # Re-queues ONLY the failed rows a new attempt can fix, through the same gates as #call
    # (Enqueue rerun: a released text is sent again as released). Unlike #call it never re-sends a
    # finished CV and writes no decision. Returns the number queued.
    def self.retry_failed(job)
      stage = job.stages.find_by(code: "S1", score_source: "ai")
      return 0 if stage.nil?

      stage.participations.where(screening_state: "screening_failed").includes(:job_application)
           .select { |p| retryable?(p) }.count { |p| Enqueue.call(p, rerun: true) == :queued }
    end

    def self.retryable?(participation)
      participation.screening_state == "screening_failed" && !NEEDS_CV_TEXT.include?(participation.screening_failure) &&
        Enqueue.blocked_reason(participation).nil?
    end
  end
end
