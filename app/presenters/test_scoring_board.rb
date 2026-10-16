# "Technical test scoring" (D60 slice 5): the answers waiting for the reviewer, the ones already
# scored, and why the others are not in the list. Loaded once here; the view only prints.
#
# Numbering: client roles see "Kandidat NN", the same number the gate box and the screening box
# use (GateBoard#participations, S1 order), so one person has one number on every screen.
class TestScoringBoard
  Row = Data.define(:number, :participation, :attempt, :review)

  attr_reader :job

  def initialize(job)
    @job = job
  end

  def gate = @gate ||= GateBoard.new(job)
  def applicable? = gate.applicable?
  def stage = gate.s2
  def version = TechnicalTestCase.current_for(job)

  # Answers to score: sent, no current S2 decision, S1 not currently eliminated (B-1).
  def to_score = rows.select { |row| row.review.nil? && !decided?(row) && !s1_eliminated?(row) }
  def scored = rows.select(&:review)
  # Sent, but S1 currently eliminated: not scored, gate_eliminated at close.
  def excluded = rows.select { |row| row.review.nil? && s1_eliminated?(row) }

  # Applicants who have not sent an answer, by technical-test state (from the same clock rules the
  # candidate sees).
  def not_answered_counts
    @not_answered_counts ||= unanswered.map { |p| TechnicalTests::Status.new(p.job_application).state }.tally
  end

  def number_for(participation) = numbers.fetch(participation.job_application_id, 0)

  private

  def rows
    @rows ||= attempts.map do |attempt|
      Row.new(number: number_for(attempt.participation), participation: attempt.participation, attempt:,
              review: reviews[attempt.participation_id])
    end.sort_by(&:number)
  end

  def attempts
    @attempts ||= TestAttempt.where(participation_id: s2_participations.map(&:id)).where.not(answered_at: nil)
                             .includes({ participation: { job_application: :candidate } }, { test_case: :criteria })
                             .order(:answered_at).to_a
  end

  def unanswered
    answered = attempts.map(&:participation_id)
    s2_participations.reject { |p| answered.include?(p.id) }
  end

  def s2_participations = @s2_participations ||= stage ? stage.participations.includes(job_application: :candidate).order(:id).to_a : []
  def reviews = @reviews ||= TestReview.where(participation_id: attempts.map(&:participation_id)).includes(:reviewer, :score_entry, :decision).index_by(&:participation_id)
  def decisions = @decisions ||= Decision.current.where(participation_id: attempts.map(&:participation_id)).index_by(&:participation_id)
  def decided?(row) = decisions.key?(row.participation.id)

  def s1_decisions
    @s1_decisions ||= gate.participations.to_h { |p| [p.job_application_id, p] }.then do |by_app|
      currents = Decision.current.where(participation_id: by_app.values.map(&:id)).index_by(&:participation_id)
      by_app.transform_values { |p| currents[p.id] }
    end
  end

  def s1_eliminated?(row) = s1_decisions[row.participation.job_application_id]&.outcome == "eliminate"

  def numbers
    @numbers ||= gate.participations.each_with_index.to_h { |p, i| [p.job_application_id, i + 1] }
  end
end
