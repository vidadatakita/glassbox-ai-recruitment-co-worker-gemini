module Interviews
  # One answer from the candidate. Before any AI call the answer is neutralised (fences), redacted and
  # checked (Screening::Redactor, ResidualCheck, InjectionCheck); a turn that trips a check is HELD: it is
  # stored for staff, never sent to the AI, never part of the <interview> text, and the chat goes on.
  #
  # position: is the turn the form showed. A repeat (double click, second tab) or a stale form finds the
  # turn already answered and is refused before any AI call.
  class Answer
    Result = Data.define(:status, :turn, :next_turn) # :accepted | :held | :retry (AI busy, answer kept) | :finished | :refused

    def self.call(interview:, text:, position: nil, now: Time.current) = new(interview, text, position, now).call

    def initialize(interview, text, position, now)
      @interview = interview
      @text = text.to_s.strip
      @position = position
      @now = now
    end

    def call
      Interviews::Expire.call(@interview, now: @now)
      return refused unless @interview.reload.open?
      return refused if @text.empty? || @text.length > Interview::MAX_ANSWER

      turn = store_answer
      return refused unless turn

      held = turn.held
      return finish(turn, "completed") if turn.position >= Interview::MAX_TURNS

      case (following = Interviews::Next.call(@interview.reload, now: @now)).status
      when :ok then Result.new(status: held ? :held : :accepted, turn:, next_turn: following.turn)
      when :retry then Result.new(status: :retry, turn:, next_turn: nil)
      else Result.new(status: :finished, turn:, next_turn: nil)
      end
    end

    private

    # The one unanswered turn, only when it is the one the candidate saw. Written inside the interview's lock
    # so two requests cannot both answer it.
    def store_answer
      @interview.with_lock do
        turn = @interview.turns.reload.last
        next nil if turn.nil? || turn.answered_at || (@position && @position.to_i != turn.position)

        clean = cleaned
        turn.update!(answer_raw: @text, answered_at: @now, held: clean.nil?, answer_clean: clean)
        turn
      end
    end

    # The redacted text, or nil when a check says it must not go to the AI.
    def cleaned
      names = [@interview.job_application.candidate&.name].compact
      redacted = Screening::Redactor.call(Screening::InjectionCheck.neutralise_fences(@text), names:).text
      return nil if Screening::ResidualCheck.findings(redacted, names:).any? || Screening::InjectionCheck.suspicious?(@text)

      redacted
    end

    def finish(turn, reason)
      Interviews::Finish.call(@interview, reason:, now: @now)
      Result.new(status: :finished, turn:, next_turn: nil)
    end

    def refused = Result.new(status: :refused, turn: nil, next_turn: nil)
  end
end
