module ScreeningReport
  # "Skor Tes Teknis (S2)" (SPEC §1): the reviewer's rubric score 0-100 (feature 07, T1), or a state
  # when there is no score. Read DEFENSIVELY: the answer and rubric columns arrive with feature 07
  # slices 3-5 (test_attempts.answered_at / grace_seconds); while they do not exist the cell still
  # gives an honest state from what does (start marker, attendance, decision).
  #
  # States, in the order they are checked:
  #   none            the job's package has no S2 (package 2)            "No test"
  #   gate_eliminated S1 eliminated at gate close (feature 07)            "Not scored"
  #   scored          a current S2 ScoreEntry                            the score
  #   expired         no-show (rule 5), or the start window / the timer
  #                   ran out without an answer                          "expired"
  #   awaiting_review an answer arrived, no score yet                    "awaiting scoring"
  #   in_progress     started, timer still running                       "in progress"
  #   not_started     no start yet, start window still open              "not started"
  module TestCell
    # D60: the test must START within 48 hours of the submitted application (plan §b).
    START_WINDOW = 48.hours
    # Used only when the attempt row does not record its own grace yet (slice 2 schema).
    DEFAULT_GRACE_SECONDS = 120
    LABELS = {
      none: "No test", gate_eliminated: "Not scored", expired: "expired",
      awaiting_review: "awaiting scoring", in_progress: "in progress", not_started: "not started"
    }.freeze

    Cell = Data.define(:state, :score) do
      def label = state == :scored ? nil : LABELS.fetch(state)
    end

    module_function

    def of(participation:, decision:, score:, attempt:, submitted_at:, now: Time.current)
      return Cell.new(state: :none, score: nil) if participation.nil?
      return Cell.new(state: :gate_eliminated, score: nil) if decision&.reason_code == "gate_eliminated"
      return Cell.new(state: :scored, score:) unless score.nil?

      Cell.new(state: state_without_score(participation, decision, attempt, submitted_at, now), score: nil)
    end

    def state_without_score(participation, decision, attempt, submitted_at, now)
      return :expired if participation.attendance == "no_show" || decision&.reason_code == "no_show"
      return attempt_state(attempt, now) if attempt
      return :expired if submitted_at && now > submitted_at + START_WINDOW

      :not_started
    end

    def attempt_state(attempt, now)
      return :awaiting_review if attempt.respond_to?(:answered_at) && attempt.answered_at.present?

      grace = attempt.respond_to?(:grace_seconds) ? attempt.grace_seconds.to_i : DEFAULT_GRACE_SECONDS
      now > attempt.due_at + grace.seconds ? :expired : :in_progress
    end
  end
end
