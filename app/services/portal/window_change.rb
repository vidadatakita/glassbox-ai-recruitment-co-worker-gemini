module Portal
  # Opens, closes or reopens a job's portal (BP §3.6 A). Who: the HR Admin or the superadmin (three
  # roles, 17 Oct 2026; the actor's role is logged). Every change is an appended event.
  class WindowChange
    class Refused < StandardError; end

    ROLES = %w[hr_admin superadmin].freeze

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
      refuse!("Only the HR Admin can open the portal.") unless ROLES.include?(@actor.role)
      refuse!("The portal has been opened before. Use Reopen with a reason.") if @job.application_window_events.exists?
      check_preconditions!(closes_at)
      raise_unless_ad_reason_recorded!
      # One transaction (test engine F4/F5, 17 Oct 2026): the ad approval, the AI tier snapshot, the window
      # event and the history row land together or not at all. Without it a failing event or history row
      # left the ad stamped approved by an open that never happened, and the retry kept the failed
      # opener's name. The job row is locked and "opened before?" asked again inside (test engine G2):
      # two simultaneous opens otherwise both pass the check above and append two open events.
      ActiveRecord::Base.transaction do
        @job.lock!
        refuse!("The portal has been opened before. Use Reopen with a reason.") if @job.application_window_events.exists?
        # FLOW §9 rule 2: the tier → model mapping in force now is locked on the vacancy; a later change of
        # the environment never alters this vacancy's results. Stored once, at the first open.
        @job.update!(ai_model_tiers: Screening::Config.tiers_snapshot)
        approve_ad!
        append("open", closes_at:, quota:)
      end
    end

    def close!(reason:)
      refuse!("Only the HR Admin can close the portal.") unless ROLES.include?(@actor.role)
      refuse!("The portal is not open.") unless ApplicationWindow.new(@job, now: @now).open?
      append("close", reason:)
    end

    def reopen!(reason:, closes_at:, quota:)
      refuse!("Only the HR Admin can open the portal.") unless ROLES.include?(@actor.role)
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
      # A vacancy opened before 17 Oct (or by a plant) may carry no approver: the reopener becomes it,
      # in the same transaction as the event (test engine F6).
      ActiveRecord::Base.transaction do
        approve_ad!
        append("reopen", reason:, closes_at:, quota:)
      end
    end

    private

    # Opening the portal shows the ad to applicants, so it is the ad's approval: stamped once, under
    # the opener's name, and recorded in the brief history like the former approval step.
    def approve_ad!
      # Read from the database, not the in-memory record: after a rolled-back open the record still
      # carries the stamp it was given, and the retry would keep the failed opener's name (test engine).
      return if Job.where(id: @job.id).where.not(ad_approved_at: nil).exists?

      @job.update!(ad_approved_at: @now, ad_approved_by_id: @actor.id)
      JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "ad", created_at: @now,
                             changes_made: { "ad_approved_at" => [nil, @now.iso8601], "approved_by" => ["", "portal open"] })
    end

    # Test engine F2 (17 Oct 2026): an ad whose text names a protected attribute (a rule flag) goes live
    # only with the writer's reason on record. Since the reason is asked at save, this refuses only data
    # saved before that rule: the writer re-saves the ad with a reason (Briefs::SaveAd records it).
    def raise_unless_ad_reason_recorded!
      # The rules are run on the TEXT, not read from the stored flags (test engine G1): flags stored before
      # a rule existed, or written around SaveAd, would otherwise let a named protected attribute go live.
      # Rule check only (no AI call), the same table SaveAd applies.
      return unless Briefs::AdCheck.rule_hit?(Briefs::AdCheck.rule_flags(@job.ad_text.to_s))

      last = @job.brief_changes.where(step: "ad").order(:id).reverse.find do |change|
        change.changes_made.key?("ad_text") || change.changes_made.key?("ad_flags_reason")
      end
      return if last&.changes_made&.dig("ad_flags_reason", 1).to_s.strip.present?

      refuse!("The job ad names a protected attribute and no reason is recorded. Open the job ad, write why the work needs it, and save.")
    end

    # D32: no retention period, no consent text that states one, no portal. Process card 4: the
    # ad must be approved before anyone can apply to it.
    def check_preconditions!(closes_at)
      refuse!("The vacancy is not linked to a company.") if @job.client_company.nil?
      # Test engine F1 (17 Oct 2026): the server, not only the card, requires a complete brief.
      refuse!("The vacancy brief is not complete yet. Complete it before opening the portal.") unless @job.brief_complete?
      # The technical test must be in force before anyone can apply (GlassBox Team, 17 Oct 2026): an
      # applicant who reaches the test stage with no test would be an unfair no-show. The rule (which
      # test counts, packages without a test) lives in TestCases::Readiness, owned with the test bank.
      refuse!(TestCases::Readiness.refusal(@job)) unless TestCases::Readiness.ready_for_open?(@job)
      # D40a: while CV screening is closed the window stays closed; opening would report success
      # while nobody can apply (test engine G4).
      refuse!("CV screening for this vacancy has closed. The portal cannot be reopened.") if ApplicationWindow.new(@job, now: @now).first_stage_closed?
      blockers = ConsentReadiness.blockers(@now, company: @job.client_company)
      refuse!("The portal cannot be opened: #{blockers.join(' ')}") if blockers.any?
      # 17 Oct 2026: there is no separate approval step; the ad must be written, and opening the
      # portal IS the approval (recorded below under the opener's name).
      # A vacancy approved before the ad had a text (Job#legacy_ad?) still opens, as it did before.
      refuse!("The job ad has not been written yet.") if @job.ad_text.blank? && @job.ad_approved_at.nil?
      refuse!("The automatic closing time must be after now.") if closes_at && closes_at <= @now
    end

    def append(action, closes_at: nil, quota: nil, reason: nil)
      ApplicationWindowEvent.create!(job: @job, action:, closes_at:, quota:, reason: reason.presence,
                                     actor_id: @actor.id, actor_role: @actor.role, created_at: @now)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
