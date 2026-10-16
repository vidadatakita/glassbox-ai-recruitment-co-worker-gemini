# The AI's proposal for a job brief, exactly as it was proposed (Briefs::Suggest). Never edited:
# the person edits the brief itself, and the brief page compares the two (BriefSuggestionDiff).
#
# payload: { "success_90d" => "...",
#            "activities" => [{ "description", "output", "share_percent" }],
#            "requirements" => [{ "tier", "text", "cv_evidence", "weight", "knockout" }],
#            "dropped" => n }  # lines removed because they named a protected attribute
class BriefSuggestion < ApplicationRecord
  include AppendOnly

  belongs_to :job
  belongs_to :actor, class_name: "User"

  def activities = payload.fetch("activities", [])
  def requirements = payload.fetch("requirements", [])
  def success_90d = payload["success_90d"].to_s
  def competencies = payload.fetch("competencies", [])
  def brief? = payload.key?("activities")
  def test = payload.fetch("test", {})
  def ad_text = payload.dig("ad", "text").to_s

  # What the wizard's form shows for a step when HR picks this proposal: the proposal's rows for
  # the step it covers, the saved brief for every other field (BriefForm reads one hash).
  def form_params(step, job)
    case step
    when "2"
      { "success_90d" => success_90d, "activities" => activities.each_with_index.to_h { |a, i| [i.to_s, a] } }
    when "3"
      slots = BriefForm::REQUIREMENT_SLOTS
      rows = requirements.group_by { |r| r["tier"] }.flat_map do |tier, list|
        slots.fetch(tier).first(list.size).zip(list)
      end
      { "salary_min" => rupiah(job.salary_min), "salary_max" => rupiah(job.salary_max), "show_salary" => job.show_salary,
        "placements" => job.placements, "relocation" => job.relocation, "work_arrangement" => job.work_arrangement,
        "requirements" => rows.to_h { |slot, r| [slot.to_s, r] } }
    when "5"
      # The step-5 form (TestCaseForm) reads these keys; the case file is never proposed.
      { "instructions" => test["instructions"].to_s, "time_limit_minutes" => test["time_limit_minutes"].to_s,
        "answer_types_submitted" => "1", "answer_types" => Array(test["answer_types"]), "new_version_reason" => "",
        "criteria" => Array(test["criteria"]).each_with_index.to_h { |c, i| [i.to_s, c.transform_values(&:to_s)] } }
    when "4"
      { "package" => job.package, "package_override_reason" => job.package_override_reason, "stage_plan" => job.stage_plan || {},
        "competencies" => competencies.each_with_index.to_h { |c, i| [i.to_s, c] } }
    end
  end

  private

  def rupiah(value) = value && ActiveSupport::NumberHelper.number_to_delimited(value, delimiter: ".")
end
