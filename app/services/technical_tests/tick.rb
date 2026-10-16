module TechnicalTests
  # The recurring pass over every open technical test (config/recurring.yml, every 5 minutes in
  # production): expiry -> no_show (TechnicalTests::Expire), the 24-hour reminder, and the
  # gate-outcome notice for gates that have closed. Each step is idempotent, so running it twice,
  # or late, writes nothing new. Errors are NOT rescued: a failing tick fails the job, which the
  # queue records and retries; a swallowed error here would silently stop no-shows and reminders.
  module Tick
    module_function

    def call(now: Time.current)
      expired = Expire.sweep(now:)
      reminded = 0
      waiting_starts.find_each do |participation|
        reminded += 1 if Notices.reminder(participation.job_application, now:)&.sent?
      end
      outcomes = 0
      closed_gate_jobs.find_each do |job|
        outcomes += job.job_applications.count { |application| Notices.gate_outcome(application)&.sent? }
      end
      { expired:, reminded:, outcomes: }
    end

    # Gated S2 participations with no attempt and attendance pending (a reminder may be due).
    def waiting_starts
      Participation.joins(:stage).where(stages: { code: "S2" }).where.not(stages: { gate: nil })
                   .where.not(stages: { status: "closed" }).where(attendance: "pending")
                   .where.not(id: TestAttempt.select(:participation_id)).includes(:job_application)
    end

    def closed_gate_jobs
      Job.where(id: Stage.where(code: "S2", status: "closed").where.not(gate: nil).select(:job_id))
    end
  end
end
