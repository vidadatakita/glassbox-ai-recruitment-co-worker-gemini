module ApplicationDrafts
  # The competency-test score of one submitted three-step application, 0-100 (slice C). Every drawn
  # question weighs the same: multiple choice 100 when correct, else 0; a written answer
  # (rating - 1) / 4 x 100, the HR Manager's rating when confirmed, otherwise the AI's; an unanswered
  # question 0. complete? is false while a written answer has neither rating (the AI has not run or
  # failed). reviewed? is true when every answered written question carries the HR Manager's rating.
  #
  # Fail closed: an AI rating counts only when its quote was found in the answer AND the answer does
  # not look like an attempt to steer the AI (Screening::InjectionCheck). Otherwise the answer needs a
  # person (human_needed), whatever the vacancy average (independent test pass, slice C, F3).
  class Score
    Result = Data.define(:value, :complete, :reviewed, :written_count, :human_needed) do
      def complete? = complete
      def reviewed? = reviewed
      def human_needed? = human_needed
    end

    def self.ai_usable?(answer)
      answer.ai_rating.present? && answer.ai_quote_verified && !Screening::InjectionCheck.suspicious?(answer.answer_text.to_s)
    end

    def self.call(draft) = new(draft).call

    def initialize(draft)
      @draft = draft
    end

    def call
      answers = @draft.answers.index_by(&:bank_question_id)
      parts = []
      complete = true
      reviewed = true
      written = 0
      human = false
      @draft.questions.each do |q|
        a = answers[q.id]
        if q.multiple_choice?
          parts << (a&.choice_index == q.correct_index && !a.nil? ? 100.0 : 0.0)
        elsif a.nil? || a.answer_text.blank?
          parts << 0.0
        else
          written += 1
          reviewed &&= a.review_rating.present?
          rating = a.review_rating || (self.class.ai_usable?(a) ? a.ai_rating : nil)
          human ||= a.review_rating.nil? && !self.class.ai_usable?(a)
          rating ? parts << (rating - 1) * 25.0 : complete = false
        end
      end
      value = parts.empty? || !complete ? nil : (parts.sum / @draft.draw.size).round(2)
      Result.new(value, complete, reviewed, written, human)
    end
  end
end
