module Interviews
  # Shows the first question and starts the 30-minute clock (once). Idempotent: opening the interview
  # again returns the current turn and never moves the clock. Returns an Interviews::Next::Result.
  module Start
    module_function

    def call(interview, now: Time.current)
      return Interviews::Next::Result.new(:finished, nil) unless interview.open?

      turn = interview.turns.reload.last
      turn ? Interviews::Next::Result.new(:ok, turn) : Interviews::Next.call(interview, now:)
    end
  end
end
