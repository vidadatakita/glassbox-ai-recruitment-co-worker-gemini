# frozen_string_literal: true

module Briefs
  # Saves the job ad and checks it (Briefs::AdCheck), recording the change like every brief step.
  # The ad goes live when the portal opens (Portal::WindowChange#open! stamps the approval); after
  # that only HR edits it, and every save needs the tick (confirmed): the text shows on the apply
  # page at once, so saving it IS HR's approval of the new text. A text that names a protected
  # attribute (a rule flag, Briefs::AdCheck) is saved only with the writer's reason (reason:),
  # recorded with the change, live or not: since 17 Oct 2026 there is no separate approval step
  # where the reason could be asked later.
  class SaveAd
    # needs_reason: refused only for the missing reason; flags then holds the rule flags of the
    # unsaved text, so the page can show them beside the reason field.
    Result = Data.define(:ok, :error, :flags, :needs_reason) do
      def initialize(ok:, error:, flags:, needs_reason: false) = super
      def ok? = ok
    end

    def self.call(job:, actor:, text:, confirmed: false, reason: nil) = new(job:, actor:, text:, confirmed:, reason:).call

    def initialize(job:, actor:, text:, confirmed: false, reason: nil)
      @job = job
      @actor = actor
      @text = text.to_s.gsub("\r\n", "\n").strip
      @confirmed = confirmed
      @reason = reason.to_s.squish
    end

    def call
      return Result.new(false, "An approved job ad can only be changed by HR.", @job.ad_flags) unless @job.ad_writable_by?(@actor)
      return Result.new(false, "Write the job ad first.", []) if @text.empty?
      live = @job.ad_approved_at.present?
      if live && !@confirmed
        return Result.new(false, "Tick \"I have checked this text\": this job ad is already approved, so the text you save is shown to applicants at once.", [])
      end
      # The rules first: a text refused for the missing reason costs no AI call.
      if @reason.empty? && AdCheck.rule_hit?(rules = AdCheck.rule_flags(@text))
        return Result.new(ok: false, flags: rules, needs_reason: true,
                          error: "#{AdCheck.rule_summary(rules)} #{live ? 'This job ad is shown to applicants as soon as it is saved' : 'This job ad is shown to applicants once the portal opens'}: change the sentence, or write why the work needs it in \"Reason\".")
      end

      flags = AdCheck.call(@text)
      ActiveRecord::Base.transaction do
        before = @job.ad_text
        @job.update!(ad_text: @text, ad_flags: flags)
        # Saving with the tick IS HR's approval of this text.
        @job.update!(ad_approved_at: Time.current, ad_approved_by_id: @actor.id) if live && before != @text
        # Test engine F3 (17 Oct 2026): a re-save of the same flagged text WITH a reason is recorded too;
        # it is how an ad saved before the reason rule gets its reason on record.
        reason_given = AdCheck.rule_hit?(flags) && @reason.present?
        if before != @text || reason_given
          changes = before != @text ? { "ad_text" => [before, @text] } : {}
          changes["ad_flags_reason"] = [AdCheck.rule_categories(flags).join(", "), @reason] if AdCheck.rule_hit?(flags)
          JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "ad", changes_made: changes, created_at: Time.current)
        end
      end
      Result.new(true, nil, flags)
    end
  end
end
