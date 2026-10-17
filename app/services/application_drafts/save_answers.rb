module ApplicationDrafts
  # Saves the answers as typed (autosave, and the form's own buttons). Only drawn questions, only while
  # the time runs (deadline + grace) and before Submit; the trigger draft_answers_guard repeats all
  # three. A multiple-choice answer is the chosen option's index; a written answer is its text.
  # Returns the number saved, or an error sentence.
  module SaveAnswers
    Result = Data.define(:saved, :error)
    MAX_TEXT = 4000

    module_function

    def call(draft, raw, now: Time.current)
      return Result.new(0, "This application is already submitted.") if draft.submitted?
      return Result.new(0, "Start the test first.") unless draft.test_started?
      return Result.new(0, "The time for the test is over. Your saved answers are kept; submit your application.") if draft.time_over?(now)

      questions = draft.questions.index_by { |q| q.id.to_s }
      saved = 0
      DraftAnswer.transaction do
        raw.to_h.each do |id, value|
          question = questions[id.to_s]
          next if question.nil?

          attrs = question.multiple_choice? ? choice(question, value) : { choice_index: nil, answer_text: value.to_s.strip[0, MAX_TEXT].presence }
          next if attrs.nil?

          answer = DraftAnswer.find_or_initialize_by(application_draft: draft, bank_question: question)
          answer.update!(attrs.merge(saved_at: now))
          saved += 1
        end
      end
      Result.new(saved, nil)
    end

    def choice(question, value)
      index = Integer(value.to_s, exception: false)
      return nil unless index&.between?(0, question.options.size - 1)

      { choice_index: index, answer_text: nil }
    end
  end
end
