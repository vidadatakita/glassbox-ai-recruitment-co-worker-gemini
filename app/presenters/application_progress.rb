# frozen_string_literal: true

# One applicant's journey as a stepper (applicant page, 17 Oct 2026), the same shape as HiringProgress so
# one partial draws it. Each step reads the record it writes: when it happened and who acted. No score is
# shown here, so the calibration blinding (D13) is not touched; scores live in the Score matrix.
class ApplicationProgress
  Step = HiringProgress::Step

  def initialize(application)
    @application = application
    @participations = application.participations.includes(:stage).index_by { |p| p.stage.code }
  end

  def steps
    @steps ||= [
      Step.new(:applied, "Applied", "fa-paper-plane-o", "Applicant", @application.created_at, "Applicant"),
      release_step,
      screening_step,
      decision_step,
      *later_stage_steps,
      salary_step,
      offer_step
    ]
  end

  def current_key = steps.find { |s| !s.done? }&.key
  def complete? = current_key.nil?
  def done_count = steps.count(&:done?)

  private

  def s1 = @participations["S1"]

  def release_step
    action = s1 && AiReleaseAction.joins(:ai_release).where(ai_releases: { participation_id: s1.id }, action: "released").order(:created_at).first
    result = s1&.screening_results&.order(:created_at)&.first
    at, actor = if action then [action.created_at, action.actor]
                elsif result then [result.created_at, "Recorded"]
                end
    Step.new(:release, "Sent to Gemini", "fa-shield", "HR Manager", at, actor)
  end

  def screening_step
    result = s1&.screening_results&.order(:created_at)&.first
    Step.new(:screening, "AI screening", "fa-magic", "Gemini", result&.created_at, result && "Gemini")
  end

  def decision_step
    choice = s1 && ProgressionChoice.where(participation_id: s1.id).order(:created_at).first
    Step.new(:decision, "Step decision", "fa-check-square-o", "HR Admin", choice&.created_at, choice&.actor)
  end

  # Every stage after CV screening that the vacancy runs: done when it has a recorded result.
  def later_stage_steps
    codes = @application.job.stages.map(&:code).sort_by { |c| Stage::CODES.index(c) || 99 } - ["S1"]
    codes.map do |code|
      p = @participations[code]
      decision = p&.current_decision
      entry = p&.score_entries&.current&.order(:entered_at)&.first
      # The time and the person come from the same record: the decision when there is one, else the score.
      at, actor = if decision then [decision.decided_at, User.find_by(id: decision.decided_by_id) || "Recorded"]
                  elsif entry then [entry.entered_at, User.find_by(id: entry.entered_by_id) || "Recorded"]
                  end
      icon = code == "S2" ? "fa-file-text-o" : "fa-comments-o"
      Step.new(:"stage_#{code}", CandidateStatus::STAGE_LABELS.fetch(code, code), icon, code == "S2" ? "HR Manager" : "HR Admin", at, actor)
    end
  end

  def salary_step
    agreement = SalaryAgreement.where(job_application_id: @application.id).order(:created_at).first
    Step.new(:salary, "Salary agreed", "fa-money", "HR Manager", agreement&.created_at, agreement&.decided_by)
  end

  def offer_step
    offer = @application.offer_documents.order(:created_at).first
    Step.new(:offer, "Offer sent", "fa-envelope-o", "HR Admin", offer&.created_at, offer && User.find_by(id: offer.uploaded_by_id))
  end
end
