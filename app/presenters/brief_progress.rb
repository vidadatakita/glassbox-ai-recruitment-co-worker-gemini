# frozen_string_literal: true

# The vacancy brief's own workflow as a stepper (brief page, 17 Oct 2026), the same shape as
# HiringProgress so one partial draws both. A step is done when the brief check finds no open problem
# in it AND it has been saved; when it was last saved and by whom come from the brief history. A brief
# written outside the wizard (the demo seed) has no history for a step: it is shown done at the brief's
# completion time, "Recorded", never with an invented name.
class BriefProgress
  Step = HiringProgress::Step

  def initialize(job)
    @job = job
    @check = Briefs::BriefCheck.new(job)
  end

  def steps
    @steps ||= [
      wizard(1, "Position", "fa-id-card-o"),
      wizard(2, "Activities", "fa-list-ol"),
      wizard(3, "Requirements", "fa-check-square-o"),
      discrimination,
      wizard(4, "Package & stages", "fa-cubes"),
      (wizard(5, "Technical test", "fa-file-text-o") if TestCases::Requirement.applies?(@job)),
      completion
    ].compact
  end

  def current_key = steps.find { |s| !s.done? }&.key
  def complete? = current_key.nil?
  def done_count = steps.count(&:done?)

  private

  def wizard(number, label, icon)
    open = @check.for_step(number).any?
    change = @job.brief_changes.where(step: number.to_s).order(:id).last
    at, actor = if open then [nil, nil]
                elsif change then [change.created_at, change.actor]
                elsif @job.brief_complete? then [@job.brief_completed_at, "Recorded"]
                end
    Step.new(:"step#{number}", label, icon, "HR Admin", at, actor)
  end

  # Appendix D: every requirement read by the discrimination check, and each flagged line decided.
  def discrimination
    data = @job.requirement_check || {}
    done = Briefs::RequirementCheck.ran?(@job) && !Briefs::RequirementCheck.stale?(@job) && Briefs::RequirementCheck.open_lines(@job).empty?
    at = data["checked_at"].present? ? Time.zone.parse(data["checked_at"]) : @job.brief_completed_at
    Step.new(:discrimination, "Discrimination check", "fa-balance-scale", "Gemini + HR Admin", (at if done), ("Recorded" if done))
  end

  def completion
    change = @job.brief_changes.where(step: "complete").order(:id).last
    at = @job.brief_complete? ? (@job.brief_completed_at || change&.created_at) : nil
    Step.new(:complete, "Brief complete", "fa-flag-checkered", "HR Admin", at, at && (change&.actor || "Recorded"))
  end
end
