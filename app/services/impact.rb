# AI Builder Cup standard item 1, "before / after" (Impact summary), measured from the records of
# the given jobs only; every number says what it counts. The BEFORE side is the client's own figure
# (Settings, baseline_*): never invented here.
#
#   hours_to_answer   median hours from an application to its first answer: the AI screening result,
#                     a decision, or a person's choice, whichever came first
#   human_read_pct    share of screened CVs a person still had to read (held for the release check,
#                     not sent, unreadable, failed, or reviewed); the rest the AI read first
#   reasoned_pct      share of the choices that moved a candidate with a written reason: the
#                     chooser's note or the AI recommendation's reasons it was made on
#   agreement_pct     share of choices that went the AI's way (D63 §5), flagged below 50% or above 95%
#                     over at least 20 choices (a person who never disagrees may not be reading)
# ponytail: computed in Ruby over the jobs' rows; move to SQL when a company has thousands of applications.
class Impact
  Figure = Data.define(:value, :count)

  def initialize(jobs)
    @applications = JobApplication.where(job_id: jobs.select(:id))
  end

  def applications = @applications.count

  # Demo seeds mark every AI row with this model id (db/seeds/demo_*.rb), so the page can say the
  # figures include invented data, and never says so of real data.
  DEMO_MODEL = "demo-tanpa-ai (data contoh)".freeze

  def includes_demo? = ScreeningResult.joins(:participation).where(model_id: DEMO_MODEL, participations: { job_application_id: @applications.select(:id) }).exists?

  def hours_to_answer
    spans = first_answers.filter_map { |app, at| at && ((at - app.created_at) / 1.hour) }.select(&:positive?)
    Figure.new(median(spans)&.round(1), spans.size)
  end

  def human_read_pct
    screened = s1_participations.select { |p| p.screening_state.present? }
    read = screened.count { |p| %w[awaiting_release not_sent cv_unreadable screening_failed].include?(p.screening_state) || reviewed_ids.include?(p.id) }
    Figure.new(pct(read, screened.size), screened.size)
  end

  def reasoned_pct
    choices = ProgressionChoice.joins(:participation).where(participations: { job_application_id: @applications.select(:id) }).to_a
    Figure.new(pct(choices.count { |c| c.note.present? || c.stage_recommendation_id }, choices.size), choices.size)
  end

  def agreement_pct
    pairs = ProgressionChoice.joins(:participation, :stage_recommendation)
                             .where(participations: { job_application_id: @applications.select(:id) }, stage_recommendations: { status: "ready" })
                             .pluck(:direction, "stage_recommendations.advice")
    Figure.new(pct(pairs.count { |d, a| d == a }, pairs.size), pairs.size)
  end

  def agreement_flag
    figure = agreement_pct
    return nil if figure.count < 20 || figure.value.nil?
    return "Almost always follows the AI advice: make sure it is actually read." if figure.value > 95
    return "Often differs from the AI advice: check whether the rubric or the brief needs fixing." if figure.value < 50

    nil
  end

  private

  def s1_participations = @s1 ||= Participation.joins(:stage).where(job_application_id: @applications.select(:id), stages: { code: "S1" }).to_a
  def reviewed_ids = @reviewed ||= ScreeningReview.where(participation_id: s1_participations.map(&:id)).pluck(:participation_id).to_set

  def first_answers
    ids = @applications.pluck(:id)
    firsts = Hash.new { |h, k| h[k] = [] }
    ScreeningResult.joins(:participation).where(participations: { job_application_id: ids }).pluck("participations.job_application_id", :created_at).each { |a, t| firsts[a] << t }
    Decision.joins(:participation).where(participations: { job_application_id: ids }).pluck("participations.job_application_id", :decided_at).each { |a, t| firsts[a] << t }
    ProgressionChoice.joins(:participation).where(participations: { job_application_id: ids }).pluck("participations.job_application_id", :created_at).each { |a, t| firsts[a] << t }
    @applications.map { |app| [app, firsts[app.id].min] }
  end

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def pct(part, whole) = whole.zero? ? nil : (100.0 * part / whole).round
end
