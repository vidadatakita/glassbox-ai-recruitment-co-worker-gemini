# The Portal Pelamar window of one job (BP §3.6 A and C). Never stored: derived from the latest
# manual event (open / close / reopen), the close time and quota set with it, and the number of
# applications. So there is one truth, and an automatic close needs no scheduler to take effect:
# a submission after closes_at or at the quota is refused because this object says closed.
class ApplicationWindow
  STATES = %i[never_opened open closed_by_hr closed_by_date closed_by_quota closed_by_stage closed_by_settings].freeze

  attr_reader :job, :now

  def initialize(job, now: Time.current, application_count: nil)
    @job = job
    @now = now
    @application_count = application_count
  end

  def latest_event
    @latest_event ||= job.application_window_events.order(:created_at, :id).last
  end

  def closes_at = latest_event&.closes_at
  def quota = latest_event&.quota
  def application_count = @application_count ||= job.job_applications.where.not(candidate_id: nil).count

  def state
    return :never_opened if latest_event.nil?
    return :closed_by_hr if latest_event.action == "close"
    # Inclusive close: at exactly closes_at the window is closed ("ditutup pukul 17.00" means
    # a submission at 17.00:00 is late).
    return :closed_by_date if closes_at && now >= closes_at
    # The application that reaches the quota is accepted; the next one is refused.
    return :closed_by_quota if quota && application_count >= quota
    # D40 (2026-10-10): once the first stage (Seleksi CV) has closed, nobody can join it, so
    # the window counts as closed; otherwise a late application sat on the closed stage forever
    # (test engine F4). Derived like the others: nothing is written.
    return :closed_by_stage if first_stage_closed?
    # D32/D38: the portal accepts nothing while the retention period is missing or the consent text
    # in force is missing or still holds a [PLACEHOLDER] line. WindowChange refuses to OPEN in that
    # case; this keeps an open portal from accepting if the condition arises later.
    return :closed_by_settings unless Portal::ConsentReadiness.ready?(now, company: job.client_company)

    :open
  end

  def open? = state == :open

  def first_stage_closed?
    job.stages.where.not(code: "RC").order(:code).first&.status == "closed"
  end

  # When the window closed (or will close by date), for the "ditutup" message.
  def closed_at
    case state
    when :closed_by_hr then latest_event.created_at
    when :closed_by_date then closes_at
    end
  end

  def remaining_quota
    quota && [quota - application_count, 0].max
  end
end
