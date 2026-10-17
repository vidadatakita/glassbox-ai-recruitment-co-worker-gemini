# frozen_string_literal: true

# The vacancy's workflow as a stepper (vacancy page, 17 Oct 2026): each step, when it was first done and
# by whom, read from the records the steps already write. Nothing is stored here and nothing is
# inferred: a step with no record is "pending", and the first pending step is "current".
#
# Also the approval chain: which person holds each role ON THIS VACANCY, taken from who actually acted
# (or, before anyone acted, the role that will). Display only; the rules live in the services.
class HiringProgress
  # count: how many applicants this step has handled (nil where the step is about the vacancy itself).
  Step = Data.define(:key, :label, :icon, :role, :at, :actor, :count) do
    def initialize(key:, label:, icon:, role:, at:, actor:, count: nil) = super
    def done? = at.present?
  end
  Link = Data.define(:label, :role, :person)

  def initialize(job)
    @job = job
  end

  def steps
    @steps ||= begin
      list = [
        step(:brief, "Brief", "fa-pencil-square-o", "HR Admin", *brief_done),
        step(:ad, "Job ad", "fa-bullhorn", "HR Admin", *ad_done),
        (step(:test, "Technical test", "fa-file-text-o", "HR Admin", *test_done) if TestCases::Requirement.applies?(@job)),
        step(:open, "Portal open", "fa-unlock", "HR Admin", *window_event("open")),
        step(:release, "Sent to Gemini", "fa-paper-plane", "HR Manager", *release_done),
        step(:decision, "Step decision", "fa-check-square-o", "HR Admin", *decision_done),
        step(:interview, "Interviews", "fa-comments-o", "Assessors", *interview_done),
        step(:salary, "Salary agreed", "fa-money", "HR Manager", *salary_done),
        step(:close, "Portal closed", "fa-lock", "HR Admin", *window_event("close"))
      ].compact
      list
    end
  end

  def current_key = steps.find { |s| !s.done? }&.key
  def complete? = current_key.nil?
  def done_count = steps.count(&:done?)

  def chain
    [
      Link.new("Prepares the vacancy", "HR Admin", person(@job.consultant || first_person(brief_done))),
      Link.new("Opens the portal", "HR Admin", person(window_event("open").last)),
      Link.new("Sends CVs to Gemini", "HR Manager", person(release_done.last)),
      Link.new("Decides each step", "HR Admin", person(decision_done.last)),
      Link.new("Scores the technical test", "HR Manager", person(test_scorer)),
      Link.new("Agrees the salary", "HR Manager", person(salary_done.last))
    ]
  end

  private

  def step(key, label, icon, role, at = nil, actor = nil) = Step.new(key, label, icon, role, at, actor, counts[key])

  # Applicants handled per step (Vida, 17 Oct 2026), counted from the same records the steps read.
  def counts
    @counts ||= begin
      parts = Participation.joins(:stage).where(stages: { job_id: @job.id })
      scored = ->(codes) { parts.where(stages: { code: codes }).joins(:score_entries).distinct.count(:job_application_id) }
      {
        open: @job.job_applications.where.not(candidate_id: nil).count,
        release: ScreeningResult.joins(participation: :stage).where(stages: { job_id: @job.id }).distinct.count(:participation_id),
        test: scored.call(%w[S2]),
        decision: ProgressionChoice.joins(participation: :stage).where(stages: { job_id: @job.id, code: "S1" }).count,
        interview: scored.call(%w[S3 S5]),
        salary: SalaryAgreement.joins(:job_application).where(job_applications: { job_id: @job.id }).distinct.count(:job_application_id)
      }
    end
  end
  def first_person(pair) = pair.last
  # The chain names users only; a step recorded without a person ("Recorded") shows "Not yet".
  def person(value) = value.is_a?(User) ? value : nil

  def brief_done
    return [] unless @job.brief_complete?

    change = @job.brief_changes.where(step: "complete").order(:id).last
    [@job.brief_completed_at || change&.created_at, change&.actor || "Recorded"]
  end

  # The first saved text, or, for a vacancy whose ad was written outside the screens (the demo seed),
  # the approval stamp the portal open records.
  def ad_done
    first = first_change("ad", "ad_text")
    return first if first.any?
    return [] unless @job.ad_text.present? && @job.ad_approved_at

    [@job.ad_approved_at, User.find_by(id: @job.ad_approved_by_id)]
  end

  def first_change(step, key)
    change = @job.brief_changes.where(step:).order(:id).detect { |c| c.changes_made.key?(key) }
    change ? [change.created_at, change.actor] : []
  end

  def test_done
    version = @job.test_cases.where.not(approved_at: nil).order(:approved_at).first
    version ? [version.approved_at, version.approved_by] : []
  end

  def window_event(action)
    event = @job.application_window_events.where(action:).order(:created_at).first
    event ? [event.created_at, User.find_by(id: event.actor_id)] : []
  end

  # The first "Send to Gemini"; for results recorded without a release action (sample data, or a
  # screening run before the release gate existed) the first result's time, with no name shown.
  def release_done
    action = AiReleaseAction.joins(:ai_release).where(ai_releases: { job_id: @job.id }, action: "released").order(:created_at).first
    return [action.created_at, action.actor] if action

    result = ScreeningResult.joins(participation: :stage).where(stages: { job_id: @job.id }).order(:created_at).first
    result ? [result.created_at, "Recorded"] : []
  end

  def decision_done
    choice = ProgressionChoice.joins(participation: :stage).where(stages: { job_id: @job.id }).order(:created_at).first
    choice ? [choice.created_at, User.find_by(id: choice.actor_id)] : []
  end

  # The first interview score, from a scoring link or entered in the app, whichever came first; the
  # same records the step's count reads.
  def interview_done
    invite = InterviewerInvite.joins(participation: :stage).where(stages: { job_id: @job.id }).where.not(submitted_at: nil)
                              .order(:submitted_at).first
    entry = ScoreEntry.joins(participation: :stage).where(stages: { job_id: @job.id, code: %w[S3 S5] }).order(:entered_at).first
    candidates = []
    candidates << [invite.submitted_at, invite.interviewer_name] if invite
    candidates << [entry.entered_at, User.find_by(id: entry.entered_by_id) || "Recorded"] if entry
    candidates.min_by(&:first) || []
  end

  def salary_done
    agreement = SalaryAgreement.joins(:job_application).where(job_applications: { job_id: @job.id }).order(:created_at).first
    agreement ? [agreement.created_at, User.find_by(id: agreement.decided_by_id)] : []
  end

  def test_scorer
    entry = ScoreEntry.joins(participation: :stage).where(stages: { job_id: @job.id, code: "S2" }).where.not(entered_by_id: nil)
                      .order(:entered_at).first
    entry && User.find_by(id: entry.entered_by_id)
  end
end
