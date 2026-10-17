module TestCases
  # The three-step path of a competency test bank (Vida, 17 Oct 2026):
  #   submit   - the HR Admin confirms the work is done; refused while BankReadiness finds a problem.
  #              The questions are locked from then on (trigger bank_questions_freeze).
  #   withdraw - the HR Admin takes a submitted bank back to draft to change it.
  #   return   - the HR Manager sends a submitted bank back to draft with a reason the HR Admin reads.
  #   approve  - the HR Manager approves a submitted bank; never its creator, never a bank that
  #              changed since the screen was opened (seen_digest), never an incomplete one.
  # Every step writes one brief-history row (step "5") under the person who took it.
  class BankDecision
    Result = Data.define(:ok, :errors) do
      def ok? = ok
    end
    Refused = Class.new(StandardError)
    ACTIONS = %w[submit withdraw return approve].freeze
    STALE = "This question bank has changed since you opened it. Please read it again.".freeze

    def self.call(**kwargs) = new(**kwargs).call

    # seen_digest: QuestionBank#content_digest of the page the HR Manager approved from (the screen
    # always sends it; a missing value arrives as "" and is refused). nil = seeds and tests.
    def initialize(bank:, actor:, action:, reason: nil, seen_digest: nil, now: Time.current)
      @bank = bank
      @actor = actor
      @action = action.to_s
      @reason = reason.to_s.squish.presence
      @seen_digest = seen_digest
      @now = now
    end

    def call
      refuse!("Unknown step.") unless ACTIONS.include?(@action)
      ActiveRecord::Base.transaction do
        @bank.lock!
        send(:"#{@action}!")
        JobBriefChange.create!(job: @bank.job, actor: @actor, actor_role: @actor.role, step: "5", created_at: @now,
                               changes_made: { "question_bank_version" => [nil, @bank.version], "decision" => [nil, @action],
                                               "reason" => [nil, @reason] }.reject { |_, v| v.last.nil? })
      end
      Result.new(true, [])
    rescue Refused => e
      Result.new(false, e.message.split("\n"))
    end

    private

    def submit!
      refuse!(Authority.edit_refusal(@actor, @bank.job)) unless Authority.may_edit_bank?(@actor, @bank.job)
      refuse!("Version #{@bank.version} is already #{@bank.state}.") unless @bank.draft?
      problems = BankReadiness.problems(@bank)
      refuse!(problems.join("\n")) if problems.any?

      @bank.update!(submitted_at: @now, submitted_by: @actor)
    end

    def withdraw!
      refuse!(Authority.edit_refusal(@actor, @bank.job)) unless Authority.may_edit_bank?(@actor, @bank.job)
      refuse!("Only a bank waiting for approval can be taken back to draft.") unless @bank.submitted?

      @bank.update!(submitted_at: nil, submitted_by: nil)
    end

    def return!
      refuse!(Authority.review_bank_refusal(@actor, @bank)) unless Authority.may_review_bank?(@actor, @bank)
      refuse!("Only a bank waiting for approval can be returned.") unless @bank.submitted?
      refuse!("Write the reason for returning the bank, so the HR Admin knows what to change.") if @reason.nil?

      @bank.update!(submitted_at: nil, submitted_by: nil)
    end

    def approve!
      refuse!(Authority.review_bank_refusal(@actor, @bank)) unless Authority.may_review_bank?(@actor, @bank)
      refuse!("Version #{@bank.version} is already approved.") if @bank.approved?
      refuse!("The HR Admin has not submitted this question bank for approval yet.") unless @bank.submitted?
      refuse!(STALE) if !@seen_digest.nil? && @seen_digest != @bank.content_digest
      problems = BankReadiness.problems(@bank)
      refuse!(problems.join("\n")) if problems.any?

      @bank.update!(approved_at: @now, approved_by: @actor)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
