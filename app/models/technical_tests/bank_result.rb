module TechnicalTests
  # The competency-test (question bank) result of one application, read the same way by every place that
  # shows a technical-test result: the step-9 AI advice evidence (Progression::Evidence), the screening
  # report block and cell (ScreeningReport::TestBlock / TestCell). Before 18 Oct 2026 those read only the
  # case-test review (TestReview), so an applicant who took the bank test while applying showed "not
  # scored yet" there even after the HR Manager recorded the score.
  #
  # nil when the application did not take the bank test (no submitted ApplicationDraft).
  class BankResult
    Written = Data.define(:prompt, :tests, :rating, :basis)

    def self.for(application)
      return nil if application.nil? || application.id.nil?

      draft = ApplicationDraft.where(job_application_id: application.id).where.not(submitted_at: nil).first
      draft && new(draft, TechnicalTests.participation_for(application))
    end

    attr_reader :draft, :participation

    def initialize(draft, participation)
      @draft = draft
      @participation = participation
    end

    def submitted_at = draft.submitted_at
    # The recorded S2 score (ApplicationDrafts::RecordScore writes a ScoreEntry and a Decision).
    def score_entry = @score_entry ||= participation && participation.score_entries.current.order(:id).last
    def recorded? = score_entry.present?
    def score = score_entry&.value
    def recorded_by = score_entry && User.find_by(id: score_entry.entered_by_id)
    def recorded_at = score_entry&.entered_at
    # "hr_manager" (the HR Manager confirmed the written answers) or "ai_below_average" (Vida's rule).
    def basis = score_entry&.ratings&.dig("basis")
    def note = score_entry&.ratings&.dig("note")

    def answers = @answers ||= draft.answers.includes(:bank_question).to_a
    def mc_total = draft.questions.count(&:multiple_choice?)
    def mc_right = answers.count { |a| a.bank_question.multiple_choice? && a.correct }

    # Written answers with the rating that counts: the HR Manager's, else the AI's when the result was
    # recorded on the AI basis. Never the answer text (the evidence and the report do not need it).
    def written
      draft.questions.select(&:written?).map do |q|
        a = answers.find { |x| x.bank_question_id == q.id }
        rating, by = if a&.review_rating then [a.review_rating, "HR Manager"]
                     elsif a&.ai_rating && basis == "ai_below_average" then [a.ai_rating, "AI (below the vacancy average)"]
                     else [nil, a&.answer_text.present? ? "not rated yet" : "no answer (scores 0)"]
                     end
        Written.new(q.prompt, q.link_text, rating, by)
      end
    end

    def basis_label = { "hr_manager" => "confirmed by the HR Manager", "ai_below_average" => "AI ratings counted (below the vacancy average)" }[basis]
  end
end
