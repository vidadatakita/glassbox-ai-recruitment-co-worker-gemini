module Portal
  # Opens, closes or reopens a job's portal (BP §3.6 A). Who: the HR PIC, or a consultant acting
  # on HR's behalf (the actor's role is logged). Every change is an appended event.
  class WindowChange
    class Refused < StandardError; end

    ROLES = %w[hr_pic consultant].freeze

    def self.open!(job:, actor:, closes_at: nil, quota: nil, now: Time.current)
      new(job:, actor:, now:).open!(closes_at:, quota:)
    end

    def self.close!(job:, actor:, reason: nil, now: Time.current)
      new(job:, actor:, now:).close!(reason:)
    end

    def self.reopen!(job:, actor:, reason:, closes_at: nil, quota: nil, now: Time.current)
      new(job:, actor:, now:).reopen!(reason:, closes_at:, quota:)
    end

    def initialize(job:, actor:, now:)
      @job = job
      @actor = actor
      @now = now
    end

    def open!(closes_at:, quota:)
      refuse!("Only the HR owner or a consultant can open the portal.") unless ROLES.include?(@actor.role)
      refuse!("The portal has been opened before. Use Reopen with a reason.") if @job.application_window_events.exists?
      check_preconditions!(closes_at)
      # FLOW §9 rule 2: the tier → model mapping in force now is locked on the vacancy; a later change of
      # the environment never alters this vacancy's results. Stored once, at the first open.
      @job.update!(ai_model_tiers: Screening::Config.tiers_snapshot)
      append("open", closes_at:, quota:)
    end

    def close!(reason:)
      refuse!("Only the HR owner or a consultant can close the portal.") unless ROLES.include?(@actor.role)
      refuse!("The portal is not open.") unless ApplicationWindow.new(@job, now: @now).open?
      append("close", reason:)
    end

    def reopen!(reason:, closes_at:, quota:)
      refuse!("Only the HR owner or a consultant can open the portal.") unless ROLES.include?(@actor.role)
      refuse!("A reason is required to reopen.") if reason.to_s.strip.empty?
      window = ApplicationWindow.new(@job, now: @now)
      refuse!("The portal has never been opened.") if window.state == :never_opened
      refuse!("The portal is already open.") if window.open?
      check_preconditions!(closes_at)
      # A quota at or below the applications already received would reopen nothing while the screen
      # said "reopened" (test engine H1, same kind as G4). Leave the quota empty for no limit.
      if quota && quota <= window.application_count
        refuse!("The quota must be greater than the applications already received (#{window.application_count}). Leave the quota empty for no limit.")
      end
      append("reopen", reason:, closes_at:, quota:)
    end

    private

    # D32: no retention period, no consent text that states one, no portal. Process card 4: the
    # ad must be approved before anyone can apply to it.
    def check_preconditions!(closes_at)
      refuse!("The vacancy is not linked to a company.") if @job.client_company.nil?
      # D40a: while CV screening is closed the window stays closed; opening would report success
      # while nobody can apply (test engine G4).
      refuse!("CV screening for this vacancy has closed. The portal cannot be reopened.") if ApplicationWindow.new(@job, now: @now).first_stage_closed?
      blockers = ConsentReadiness.blockers(@now, company: @job.client_company)
      refuse!("The portal cannot be opened: #{blockers.join(' ')}") if blockers.any?
      refuse!("The job ad has not been approved by HR.") if @job.ad_approved_at.nil?
      refuse!("The automatic closing time must be after now.") if closes_at && closes_at <= @now
    end

    def append(action, closes_at: nil, quota: nil, reason: nil)
      ApplicationWindowEvent.create!(job: @job, action:, closes_at:, quota:, reason: reason.presence,
                                     actor_id: @actor.id, actor_role: @actor.role, created_at: @now)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
