module Portal
  # Figures for the vacancy home (BP §3.6 A "Shown to HR"; feature plan §6; information-display
  # review 2026-10-10). Each figure carries its comparison: applications against the quota, each
  # channel against the total, each stage against the one before it, confirmations against the
  # scheduled, no-shows against attendance recorded. Everything is computed from rows loaded once.
  class JobBoard
    Row = Data.define(:application, :summary, :needs_action, :rank)
    StageRow = Data.define(:stage, :entered, :previous, :rate)

    attr_reader :job, :window, :now

    def initialize(job, now: Time.current)
      @job = job
      @now = now
      @window = ApplicationWindow.new(job, now:)
    end

    def applications = @applications ||= job.job_applications.where.not(candidate_id: nil)
                                              .includes(:candidate, participations: [:stage, :appointment, :objections]).order(:id).to_a

    # Channels, largest first, with their share of all applications (§1.1, §1.4).
    def per_channel
      total = applications.size
      applications.group_by { |a| a.channel_code.presence || "direct" }
                  .map { |channel, list| [channel, list.size, total.zero? ? 0 : (list.size * 100.0 / total).round] }
                  .sort_by { |_c, n, _p| -n }
    end

    def events = @events ||= job.application_window_events.order(:created_at, :id).to_a

    # Actor names for the window log, loaded once (no query per row).
    def actor_names = @actor_names ||= User.where(id: events.map(&:actor_id).uniq).pluck(:id, :name).to_h

    # The funnel in process order (a funnel is the one case where process order beats largest-first,
    # information-display §1.3). Each stage against the stage before it.
    def funnel
      previous = nil
      stages.map do |stage|
        entered = participations.count { |p| p.stage_id == stage.id }
        rate = previous && previous.positive? ? (entered * 100.0 / previous).round : nil
        row = StageRow.new(stage:, entered:, previous:, rate:)
        previous = entered
        row
      end
    end

    # The largest loss between two stages that both had people, as a sentence (§1.5 insight).
    def biggest_drop
      rows = funnel.each_cons(2).filter_map do |from, to|
        # Only after the earlier stage closed: before that, people still being decided are not lost.
        next if from.entered.zero? || from.stage.status != "closed"

        [from, to, from.entered - to.entered]
      end
      from, to, lost = rows.max_by { |_f, _t, l| l }
      return nil if from.nil? || lost <= 0

      "Biggest drop: #{CandidateStatus::STAGE_LABELS.fetch(from.stage.code)} to " \
        "#{CandidateStatus::STAGE_LABELS.fetch(to.stage.code)}, #{lost} of #{from.entered} applicants did not continue."
    end

    def appointments = @appointments ||= participations.filter_map(&:appointment)
    def confirmed_count = appointments.count { |a| a.confirmation == "confirmed" }
    def unconfirmed_soon = appointments.count { |a| a.confirmation == "pending" && a.starts_at.between?(now, now + 24.hours) }

    # No-show rate per stage = no_show / (attended + no_show) over participations whose attendance
    # is recorded. Pending and withdrawn are left out, so an unrecorded interview never counts.
    def no_show_by_stage
      stages.filter_map do |stage|
        recorded = participations.select { |p| p.stage_id == stage.id && %w[attended no_show].include?(p.attendance) }
        next if recorded.empty?

        [stage, recorded.count { |p| p.attendance == "no_show" }, recorded.size]
      end
    end

    def days_left
      window.closes_at && ((window.closes_at - now) / 1.day).ceil
    end

    # Applicant rows, whoever needs a person first (information-display review I7): a reschedule
    # request, an unconfirmed appointment within 24 hours, an open objection; then by stage reached,
    # furthest first; eliminated and withdrawn last.
    def rows
      applications.map do |application|
        summary = CandidateStatus.new(application, now:).summary
        parts = application.participations
        action =
          if parts.any? { |p| p.appointment&.confirmation == "reschedule_requested" } then "Requested another time"
          elsif parts.any? { |p| (a = p.appointment) && a.confirmation == "pending" && a.starts_at.between?(now, now + 24.hours) } then "Not confirmed, appointment < 24 h"
          elsif parts.any? { |p| p.objections.any? { |o| o.answered_at.nil? } } then "Objection not answered"
          end
        reached = parts.map { |p| stage_index(p.stage_id) }.max || -1
        closed_out = %w[danger muted].include?(summary.tone)
        rank = [action ? 0 : 1, closed_out ? 1 : 0, -reached, application.id]
        Row.new(application:, summary:, needs_action: action, rank:)
      end.sort_by(&:rank)
    end

    private

    def stages = @stages ||= job.stages.where.not(code: "RC").order(:code).to_a
    def participations = @participations ||= applications.flat_map(&:participations)
    def stage_index(stage_id) = stages.index { |s| s.id == stage_id } || -1
  end
end
