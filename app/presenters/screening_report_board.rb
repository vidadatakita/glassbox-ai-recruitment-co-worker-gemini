# "Screening report" for one job (feature 08; SPEC §1, D61, D62): one row per applicant
# who entered S1, with every column the list, the detail page and the xlsx show. Everything is
# loaded here in a fixed number of queries (one per table, never per row); the views and the
# workbook only print. Visibility (names, contacts) is ScreeningReport::Visibility's, not the view's.
class ScreeningReportBoard
  Row = Data.define(
    :number, :application, :candidate, :s1, :s2, :result, :s1_decision, :s2_decision, :test, :gate,
    :label_key, :label_confirmed, :confirmation, :budget, :appointment, :recommendation, :blinded
  ) do
    def ai_score = result&.score
    def band = ScreeningReport::Band.of(ai_score)
    def test_score = test.score
    def person_number = format("Candidate %02d", number)
  end

  attr_reader :job, :visibility, :now

  def initialize(job, user, now: Time.current)
    @job = job
    @user = user
    @now = now
    @visibility = ScreeningReport::Visibility.new(job, user)
  end

  def s1 = @s1 ||= job.stages.find_by(code: "S1")
  def applicable? = !s1.nil?
  def gated? = s1&.gated? || false
  def s2 = @s2 ||= (gated? ? job.stages.find_by(code: "S2", gate: s1.gate) : nil)

  # Sorted (h9): gate result (Passed, Waiting, Not passed), then the AI score 0-100 high to low,
  # then the S2 score high to low, then the earlier application first. Missing scores sort last.
  def rows
    @rows ||= numbered.sort_by do |row|
      [ScreeningReport::GateCell::ORDER.fetch(row.gate), -(row.ai_score || -1).to_f, -(row.test_score || -1).to_f,
       row.application.created_at, row.number]
    end
  end

  def row_for(application_id) = rows.find { |row| row.application.id == application_id.to_i }
  def counts = @counts ||= rows.group_by(&:gate).transform_values(&:size)
  def labels_to_confirm = rows.count { |row| row.result && !row.label_confirmed }

  def narrative_approval(result) = result && approvals[result.id]

  # Every AI-returned text goes through here before it is rendered (screen and xlsx): for a viewer
  # from whom CandidateIdentity hides identity, this candidate's name and contacts become
  # "[nama]"/"[kontak]" (engine-08 F-01). Unchanged for viewers who may see the name.
  def ai_text(row, text)
    return text if text.nil? || visibility.names?

    (@masks ||= {})[row.application.id] ||= ScreeningReport::IdentityMask.new(row.candidate)
    @masks[row.application.id].call(text)
  end

  private

  # "Candidate NN" is CandidateIdentity's number (position among the job's candidate applications by
  # id), computed here from one query so the list never asks once per row.
  def numbered
    order = JobApplication.where(job_id: job.id).where.not(candidate_id: nil).order(:id).pluck(:id)
    position = order.each_with_index.to_h { |id, i| [id, i + 1] }
    s1_list.map { |p1| build_row(p1, position.fetch(p1.job_application_id, 0)) }
  end

  def build_row(p1, number)
    p2 = s2_by_application[p1.job_application_id]
    # An unjudged calibration CV, seen by someone who judges calibration: the AI result, its label
    # and its judgements are left out of the row, so the list, the detail page and the Excel cannot
    # show them (Screening::CalibrationBlind). Human decisions and the test score stay.
    blinded = blinded?(p1)
    result = blinded ? nil : results[p1.id]
    confirmation = blinded ? nil : confirmations[p1.id]
    confirmation = nil if confirmation && result && confirmation.screening_result_id != result.id
    application = p1.job_application
    Row.new(
      number:, application:, candidate: application.candidate, s1: p1, s2: p2, result:,
      s1_decision: decisions[p1.id], s2_decision: p2 && decisions[p2.id],
      test: test_cell(p2, application), gate: ScreeningReport::GateCell.of(decisions[p1.id], p2 && decisions[p2.id], gated: gated?),
      label_key: confirmation&.label || result&.label_proposal, label_confirmed: !confirmation.nil?, confirmation:,
      budget: ScreeningReport::Budget.fit(expected_min: application.expected_salary_min, expected_max: application.expected_salary_max,
                                          band_min: job.salary_min, band_max: job.salary_max),
      appointment: appointments[application.id], recommendation: recommendations[application.id], blinded:
    )
  end

  def blinded?(p1)
    return false unless Screening::CalibrationBlind.judge?(@user, job)

    @calibration ||= Screening::Calibration.new(job)
    Screening::CalibrationBlind.blinded?(p1, @user, calibration: @calibration)
  end

  def test_cell(p2, application)
    ScreeningReport::TestCell.of(participation: p2, decision: p2 && decisions[p2.id], score: p2 && s2_scores[p2.id],
                                 attempt: p2 && attempts[p2.id], submitted_at: application.consent_at || application.created_at, now:)
  end

  def s1_list
    @s1_list ||= s1 ? Participation.where(stage_id: s1.id).includes(job_application: :candidate).order(:id).to_a : []
  end

  def s2_list = @s2_list ||= s2 ? Participation.where(stage_id: s2.id).to_a : []
  def s2_by_application = @s2_by_application ||= s2_list.index_by(&:job_application_id)
  def participation_ids = s1_list.map(&:id) + s2_list.map(&:id)
  def application_ids = s1_list.map(&:job_application_id)

  def decisions
    @decisions ||= Decision.current.where(participation_id: participation_ids).index_by(&:participation_id)
  end

  def results = @results ||= ScreeningResult.current_for(s1_list.map(&:id)).index_by(&:participation_id)

  def s2_scores
    @s2_scores ||= ScoreEntry.current.where(participation_id: s2_list.map(&:id)).group_by(&:participation_id)
                             .transform_values { |entries| Scoring::StageScore.combine(entries.map(&:value)) }
  end

  # The newest attempt per S2 participation (a candidate starts once; the newest is defensive).
  def attempts
    @attempts ||= TestAttempt.where(participation_id: s2_list.map(&:id)).order(:id).index_by(&:participation_id)
  end

  def confirmations
    @confirmations ||= ScreeningLabelConfirmation.current_for(s1_list.map(&:id)).index_by(&:participation_id)
  end

  def approvals
    @approvals ||= ScreeningNarrativeApproval.where(screening_result_id: results.values.map(&:id)).index_by(&:screening_result_id)
  end

  def recommendations = @recommendations ||= UserRecommendation.current_for(application_ids).index_by(&:job_application_id)

  # "Interview appointment": the application's next scheduled appointment from now (any stage).
  def appointments
    @appointments ||= Appointment.joins(:participation).where(participations: { job_application_id: application_ids })
                                 .where(starts_at: now..).includes(participation: :stage).order(:starts_at)
                                 .group_by { |a| a.participation.job_application_id }.transform_values(&:first)
  end
end
