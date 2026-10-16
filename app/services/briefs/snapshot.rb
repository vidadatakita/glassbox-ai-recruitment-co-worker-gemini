# frozen_string_literal: true

module Briefs
  # The fields of one wizard step as plain data, so a save can record what changed (D49 (5)
  # "every change recorded") as before -> after per field. Collections are compared as lists of
  # their visible fields; ids and timestamps are left out because they are not what a person
  # changed.
  module Snapshot
    STEP_FIELDS = {
      "1" => %w[title golongan headcount employment_type confidential],
      "2" => %w[success_90d],
      "3" => %w[salary_min salary_max show_salary placements relocation work_arrangement],
      "4" => %w[package package_override_reason stage_plan]
    }.freeze

    module_function

    def take(job, step)
      data = STEP_FIELDS.fetch(step).to_h { |f| [f, job.public_send(f)] }
      data.merge(collections(job, step))
    end

    # Field => [before, after] for every field that differs.
    def diff(before, after)
      (before.keys | after.keys).each_with_object({}) do |key, out|
        out[key] = [before[key], after[key]] unless before[key] == after[key]
      end
    end

    def collections(job, step)
      case step
      when "2" then { "activities" => job.activities.reload.map { |a| a.slice(:description, :output, :share_percent) } }
      when "3" then { "requirements" => requirement_rows(job) }
      when "4" then { "competencies" => job.competencies.reload.map { |c| competency_row(c) } }
      else {}
      end
    end

    def requirement_rows(job)
      job.requirements.reload.includes(:knockout_question).map do |r|
        r.slice(:tier, :text, :cv_evidence, :weight).merge("knockout" => r.knockout_question&.text)
      end
    end

    def competency_row(comp) = comp.slice(:name, :layer, :stage_code, :anchor_1, :anchor_3, :anchor_5, :questions)
  end
end
