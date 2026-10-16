module Screening
  # Job page action "Mulai screening": offers every S1 participation of the job to the queue again,
  # including failed screenings and finished ones whose rubric changed since, then writes the
  # automatic decisions that have become allowed (Screening::Finalize). Used after the API key is
  # set (applications that arrived while the AI was off were never queued), after a rubric fix,
  # and to retry "Screening gagal" rows. Returns { queued: n, decided: n }.
  class Start
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
  end
end
