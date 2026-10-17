module Interviews
  # An open interview that ran out of time: 30 minutes after its first question (time_up), or 48 hours
  # after the application without a first question (never_started). S1 then runs on what exists.
  # Idempotent; run by InterviewTickJob and lazily on every page that shows the interview.
  class Expire
    # subject: an Interview or a JobApplication. Returns the finished Interview, or nil when nothing expired.
    def self.call(subject, now: Time.current)
      interview = subject.is_a?(Interview) ? subject : subject.interview
      return nil unless interview&.open?

      reason = due_reason(interview, now)
      Interviews::Finish.call(interview, reason:, now:) if reason
    end

    # Every open interview that may need closing. Small sets: one install's open applications.
    def self.sweep(now: Time.current) = Interview.where(status: "open").find_each.count { |interview| call(interview, now:) }

    def self.due_reason(interview, now)
      if interview.started_at
        "time_up" if now >= interview.due_at
      elsif now >= interview.created_at + Interview::START_WINDOW
        "never_started"
      end
    end
    private_class_method :due_reason
  end
end
