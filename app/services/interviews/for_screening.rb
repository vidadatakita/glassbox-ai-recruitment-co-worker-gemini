module Interviews
  # The interview as S1 reads it. Only the clean turns (answered, not held) count.
  #   payload          the Q&A the AI sees in <interview> (cleaned answers)
  #   redacted_answers the cleaned answers only, and raw_answers the typed answers only: what QuoteCheck
  #                    matches against. The AI's own questions are NOT in them, so a question can never be
  #                    "quoted" as evidence of the candidate's experience.
  module ForScreening
    Result = Data.define(:payload, :redacted_answers, :raw_answers)

    module_function

    def for(application)
      turns = application.interview&.clean_turns
      return nil if turns.blank?

      Result.new(
        payload: turns.map { |turn| "Question #{turn.position}: #{turn.question}\nAnswer #{turn.position}: #{turn.answer_clean}" }.join("\n\n"),
        redacted_answers: turns.map(&:answer_clean).join("\n"),
        raw_answers: turns.map(&:answer_raw).join("\n")
      )
    end
  end
end
