# frozen_string_literal: true

module Briefs
  # Writes the job's Stage rows from a COMPLETE brief (blueprint §2.1 Stage: "only the stages the
  # package runs are created"). Every stage is written as a draft; opening it is the consultant's
  # step (Stages::Open), which is what locks weight and threshold (rule 3).
  #
  # A stage that has opened is never touched here; Briefs::SaveStep refuses step 4 for a locked
  # brief, so reaching one means a caller skipped that check, and this raises instead of guessing.
  # A draft stage the package no longer runs is removed, unless candidates already sit in it.
  module SyncStages
    Refused = Class.new(StandardError)

    module_function

    def call(job)
      raise Refused, "stage plan of job #{job.id} is locked: a stage has opened" if job.brief_locked?

      codes = StagePlan.codes(job.package)
      job.stages.where.not(code: codes).find_each { |stage| remove(stage) }
      codes.each { |code| write(job, code) }
    end

    def write(job, code)
      stage = job.stages.find_or_initialize_by(code:)
      plan = job.stage_plan.fetch(code, {})
      stage.update!(gate: gate_for(job, code), score_source: StagePlan.source(code),
                    weight: code == "RC" ? 0 : plan.fetch("weight"),
                    threshold: code == "RC" ? 0 : plan.fetch("threshold"),
                    review_below_threshold: StagePlan.review_below_threshold?(code, job.golongan))
    end

    # D60: when the package runs both S1 and S2 (packages 3+), the two form the gate "Seleksi CV
    # dan Tes Teknis"; package 2 runs S1 alone and has no gate.
    def gate_for(job, code)
      codes = StagePlan.codes(job.package)
      %w[S1 S2].include?(code) && (codes & %w[S1 S2]).size == 2 ? "screening" : nil
    end

    def remove(stage)
      if stage.participations.exists?
        raise Briefs::SaveStep::Refused,
              "Stage #{StagePlan::LABELS[stage.code]} already holds applicants, so the package cannot be changed to one without this stage."
      end

      stage.destroy!
    end
  end
end
