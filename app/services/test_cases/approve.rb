module TestCases
  # HR PIC approves one draft version of the job's technical test (D60, plan §c). From then on the
  # version is final (trigger test_cases_freeze) and it is what candidates start, until a newer
  # version is approved. Refused, with every problem listed, unless the version is complete.
  class Approve
    Result = Data.define(:ok, :errors) do
      def ok? = ok
    end

    def self.call(**kwargs) = new(**kwargs).call

    STALE = "This version has changed since you opened it. Please read it again.".freeze

    # seen_digest: TechnicalTestCase#content_digest of the page HR approved from (the screen always
    # sends it; a missing value from the screen arrives as "" and is refused). nil = a caller that
    # is not a screen (seeds, tests) and approves what it just built.
    def initialize(test_case:, actor:, seen_digest: nil, now: Time.current)
      @test_case = test_case
      @actor = actor
      @seen_digest = seen_digest
      @now = now
    end

    def call
      return Result.new(false, ["A technical test version is approved by HR."]) unless Authority.may_approve?(@actor)

      ActiveRecord::Base.transaction do
        @test_case.lock!
        return Result.new(false, ["Version #{@test_case.version} is already approved."]) if @test_case.approved?
        return Result.new(false, [STALE]) if !@seen_digest.nil? && @seen_digest != @test_case.content_digest

        problems = Readiness.problems(@test_case)
        return Result.new(false, problems) if problems.any?

        @test_case.update!(approved_by: @actor, approved_at: @now)
        JobBriefChange.create!(job: @test_case.job, actor: @actor, actor_role: @actor.role, step: "5",
                               changes_made: { "test_case_version" => [nil, @test_case.version], "approved" => [false, true] },
                               created_at: @now)
      end
      Result.new(true, [])
    end
  end
end
