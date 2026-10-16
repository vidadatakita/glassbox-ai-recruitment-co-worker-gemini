module TechnicalTests
  # "Start test" (plan §b): starts the candidate's technical test on the SERVER's clock and pins the
  # version. Idempotent: a second press, a refresh that re-posts, or another device returns the
  # attempt that already exists, with the same due_at (no pause, no restart).
  #
  # Refused (nothing written) when: the application is withdrawn or knocked out; the job has no
  # gated S2; S2 is closed or already decided; attendance is no longer pending; now is past
  # start_by (48 h after submit); no approved version exists. The database repeats the timer rules
  # (trigger test_attempts_guard): due_at = started_at + limit, start within 48 h, not decided.
  class Start
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(application:, now: Time.current)
      @application = application
      # Microsecond precision, as stored: due_at - started_at must equal the limit exactly in the
      # database, and a nanosecond tail would be rounded differently on the two columns.
      @now = now.floor(6)
    end

    def call
      participation = TechnicalTests.participation_for(@application)
      refuse!("This vacancy has no technical test.") if participation.nil?

      ActiveRecord::Base.transaction do
        participation.lock!
        existing = TestAttempt.find_by(participation_id: participation.id)
        return existing if existing

        check!(participation)
        version = TechnicalTestCase.current_for(@application.job)
        refuse!("The technical test is not available yet. Please open this page again later.") if version.nil?

        TestAttempt.create!(participation:, test_case: version, started_at: @now,
                            due_at: @now + version.time_limit_minutes.minutes, grace_seconds: TechnicalTests::GRACE.to_i)
      end
    end

    private

    def check!(participation)
      refuse!("This application has been withdrawn.") if @application.consent_withdrawn_at.present?
      refuse!("The technical test does not apply to this application.") if @application.knocked_out?
      if participation.stage.status == "closed" || participation.current_decision || participation.attendance != "pending"
        refuse!("The technical test is closed for this application.")
      end
      return if @now <= TechnicalTests.start_by(@application)

      refuse!("The deadline to start the technical test has passed.")
    end

    def refuse!(message) = raise(Refused, message)
  end
end
