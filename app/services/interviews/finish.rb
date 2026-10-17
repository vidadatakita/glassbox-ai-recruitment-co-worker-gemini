module Interviews
  # Closes an interview and lets S1 run. Idempotent: a finished interview is returned untouched.
  # queue: false is for Screening::Enqueue itself (HR "Mulai screening"), which queues S1 right after.
  class Finish
    def self.call(interview, reason:, now: Time.current, queue: true) = new(interview, reason, now, queue).call

    def initialize(interview, reason, now, queue)
      @interview = interview
      @reason = reason.to_s
      @now = now
      @queue = queue
    end

    def call
      @interview.with_lock do
        return @interview if @interview.finished?

        @interview.update!(status: "finished", finish_reason: @reason, finished_at: @now)
      end
      queue_screening if @queue
      @interview
    end

    private

    def queue_screening
      participation = @interview.job_application.participations.joins(:stage).find_by(stages: { code: "S1" })
      Screening::Enqueue.call(participation) if participation
    end
  end
end
