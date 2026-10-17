module ScreeningReport
  # The "Tes Teknis" block of the candidate detail (SPEC §2.4, D60): version, time used against the
  # limit, the score, the reviewer's rubric lines (criterion · weight · rating), who scored and when.
  # Read DEFENSIVELY from feature 07: the answer columns (test_attempts.answered_at) and TestReview
  # arrived with slices 3-5 while this feature was built; every read checks that the column or
  # model exists, so the block degrades to an honest "not scored yet" instead of raising.
  class TestBlock
    Line = Data.define(:name, :weight, :rating)

    attr_reader :attempt, :review

    def initialize(participation, attempt)
      @participation = participation
      @attempt = attempt
      @review = participation && defined?(::TestReview) ? ::TestReview.where(participation_id: participation.id).order(:id).last : nil
    end

    # The competency test taken while applying, when this application took it (TechnicalTests::BankResult);
    # the report shows that block instead of the case-test block.
    def bank = defined?(@bank) ? @bank : (@bank = @participation && TechnicalTests::BankResult.for(@participation.job_application))

    def applicable? = !@participation.nil?
    def started? = !attempt.nil?
    def scored? = !review.nil?
    def test_case = attempt&.test_case
    def answered_at = attempt.respond_to?(:answered_at) ? attempt.answered_at : nil

    # Whole minutes from start to the answer, rounded up (a 34 min 10 s answer used 35 minutes of
    # the limit as the candidate experienced it). nil without an answer.
    def minutes_used
      return nil if answered_at.nil?

      ((answered_at - attempt.started_at) / 60.0).ceil
    end

    def lines
      return [] unless scored? && test_case

      ratings = review.ratings.to_h
      test_case.criteria.sort_by(&:position).map do |c|
        Line.new(name: c.name, weight: c.weight, rating: ratings[c.id.to_s])
      end
    end

    def reviewer_name = review && User.find_by(id: review.reviewer_id)&.name
  end
end
