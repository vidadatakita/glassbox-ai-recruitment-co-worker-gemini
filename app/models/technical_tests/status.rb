module TechnicalTests
  # Where one application stands on its technical test, computed from the rows AND the clock, so
  # the page is right even when the expiry job has not run yet (the write side is
  # TechnicalTests::Expire). States, in the words the candidate reads (plan §e):
  #
  #   :none         no technical test in this job's apply flow (no gate, or no S2 participation)
  #   :not_started  "Not started, start by <date> at <hh:mm> WIB"
  #   :running      "In progress, N minutes left ..." (until due_at + grace; the countdown shows due_at)
  #   :sent         "Answer sent <time>"
  #   :expired      "Not taken" (not started by start_by, or no answer by due_at + grace)
  #   :closed       the test no longer applies: knockout, withdrawal, a decision already taken
  #                 (e.g. gate_eliminated after close), or the stage closed before the candidate acted
  class Status
    attr_reader :application, :now

    def initialize(application, now: Time.current)
      @application = application
      @now = now
    end

    def participation = @participation ||= TechnicalTests.participation_for(application)
    def applies? = !participation.nil?
    def attempt = @attempt ||= participation && TestAttempt.find_by(participation_id: participation.id)
    def start_by = TechnicalTests.start_by(application)
    def due_at = attempt&.due_at
    def answer_deadline = attempt && TechnicalTests.answer_deadline(attempt)
    def answered_at = attempt&.answered_at

    # The version the candidate works on: the one pinned at start, otherwise the newest approved.
    def version = attempt&.test_case || (applies? ? TechnicalTestCase.current_for(application.job) : nil)
    def time_limit = version&.time_limit_minutes

    def state
      @state ||= compute_state
    end

    def can_start? = state == :not_started && !version.nil?
    def can_answer? = state == :running

    # Whole seconds left until due_at (display only; never below zero).
    def remaining_seconds = due_at ? [(due_at - now).floor, 0].max : 0

    private

    def compute_state
      return :none unless applies?
      return :sent if attempt&.answered_at
      return :closed if application.consent_withdrawn_at.present? || application.knocked_out?
      return :expired if participation.attendance == "no_show"

      decision = participation.current_decision
      return(decision.reason_code == "no_show" ? :expired : :closed) if decision
      return :closed if participation.stage.status == "closed"

      if attempt
        now <= answer_deadline ? :running : :expired
      else
        now <= start_by ? :not_started : :expired
      end
    end
  end
end
