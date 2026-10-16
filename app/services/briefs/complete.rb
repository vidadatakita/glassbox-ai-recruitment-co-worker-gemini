# frozen_string_literal: true

module Briefs
  # Step 4 "Simpan & selesaikan brief": the brief becomes complete only when Briefs::BriefCheck
  # finds nothing (shares 100, sebaiknya weights 100, stage weights 100, thresholds 0-100, 2-3
  # knockout questions, the §2.3 coverage for the Golongan, the package override reason). Then the
  # Stage rows are written (Briefs::SyncStages) and the completion is recorded (D49 (5)).
  # Only a complete brief lets HR approve the ad (Staff::JobsController#approve_ad).
  module Complete
    Result = Data.define(:ok, :problems) do
      def ok? = ok
    end

    module_function

    def call(job:, actor:, now: Time.current)
      return Result.new(true, []) if job.brief_complete?
      if job.brief_locked?
        return Result.new(false, [BriefCheck::Problem.new(4, "A selection stage of this vacancy opened before the brief was filled in, " \
                                                               "so the brief cannot be completed through the form.")])
      end

      # Appendix D: a stale discrimination test is run here (rule pass always; AI pass when the AI is on),
      # so a clean brief completes as before and a flagged one stops with its lines on the brief page.
      RequirementCheck.ensure_current!(job:, actor:, now:)
      problems = BriefCheck.new(job).problems
      return Result.new(false, problems) if problems.any?

      ActiveRecord::Base.transaction do
        job.update!(brief_status: "complete", brief_completed_at: now)
        SyncStages.call(job)
        JobBriefChange.create!(job:, actor:, actor_role: actor.role, step: "complete",
                               changes_made: { "brief_status" => %w[draft complete] }, created_at: now)
      end
      Result.new(true, [])
    rescue SaveStep::Refused => e
      Result.new(false, e.errors.map { |m| BriefCheck::Problem.new(4, m) })
    end
  end
end
