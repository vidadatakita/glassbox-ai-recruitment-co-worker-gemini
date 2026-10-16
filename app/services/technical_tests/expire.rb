module TechnicalTests
  # Plan §a.2 / D60 16:45: a technical test not started within 48 hours, or started and with no
  # answer by due_at + grace, is a NO-SHOW on S2, eliminated by rule 5 (Scoring::Decider), never
  # averaged as zero. Idempotent: run by TechnicalTests::Tick (the recurring job) AND lazily on
  # every page that shows the test (candidate status, test page, reviewer queue), so the record is
  # right even when the job did not run.
  #
  # Two steps, each in the participation's own lock:
  #   1. the FACT: attendance pending -> no_show, written whatever the stage status (a fact is not a
  #      decision, and D37 forbids decisions only on a draft stage);
  #   2. the DECISION: rule / eliminate / no_show, only when S2 is open (D37), the participation has
  #      no current decision, and S1 is NOT currently eliminated. A candidate already out at S1 gets
  #      gate_eliminated at gate close instead (Gates::Close, plan §a.1); if their S1 elimination is
  #      reversed, the next run writes no_show. A no-show that happened while S2 was a draft gets
  #      its decision on the first run after the gate opens (Stages::Open decides knockouts and
  #      withdrawals only).
  # Withdrawn and knocked-out applications are left alone (their own rule decisions cover them).
  class Expire
    def self.call(application, now: Time.current)
      participation = TechnicalTests.participation_for(application)
      return false if participation.nil?

      new(participation, now).call
    end

    # Every gated S2 participation that may need a write. Small sets in T1 (one job's applicants).
    def self.sweep(now: Time.current)
      candidates = Participation.joins(:stage).where(stages: { code: "S2" }).where.not(stages: { gate: nil })
                                .where.not(stages: { status: "closed" }).where(attendance: %w[pending no_show])
      candidates.find_each.count { |participation| new(participation, now).call }
    end

    def initialize(participation, now)
      @participation = participation
      @now = now
    end

    # Returns true when something was written.
    def call
      ActiveRecord::Base.transaction do
        @participation.lock!
        application = @participation.job_application
        next false if application.consent_withdrawn_at.present? || application.knocked_out?

        wrote = mark_no_show(application)
        decide(application) || wrote
      end
    end

    private

    def mark_no_show(application)
      return false unless @participation.attendance == "pending" && expired?(application)

      @participation.update!(attendance: "no_show")
      true
    end

    def expired?(application)
      attempt = TestAttempt.find_by(participation_id: @participation.id)
      return false if attempt&.answered_at
      return @now > TechnicalTests.answer_deadline(attempt) if attempt

      @now > TechnicalTests.start_by(application)
    end

    def decide(application)
      return false unless @participation.attendance == "no_show"
      return false unless @participation.stage.status == "open"
      return false if @participation.current_decision
      return false if TechnicalTests.s1_eliminated?(application)

      result = Scoring::Decider.decide(score: nil, threshold: @participation.stage.threshold, attendance: :no_show)
      Decision.create!(participation: @participation, outcome: result.outcome.to_s, basis: result.basis.to_s,
                       reason_code: result.reason_code, decided_at: @now)
      true
    end
  end
end
