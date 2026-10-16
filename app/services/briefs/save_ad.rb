# frozen_string_literal: true

module Briefs
  # Saves the job ad and checks it (Briefs::AdCheck), recording the change like every brief step.
  # After HR has approved the ad, only HR edits it, and every save needs the tick (confirmed): the
  # text shows on the Lamar page at once, so saving it IS HR's approval of the new text. A text that
  # names a protected attribute (a rule flag, Briefs::AdCheck) is then saved only with HR's written
  # reason (reason:), recorded with the change: the same rule as approving a draft
  # (Staff::JobsController#approve_ad).
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
      if live && @reason.empty? && AdCheck.rule_hit?(rules = AdCheck.rule_flags(@text))
        return Result.new(ok: false, flags: rules, needs_reason: true,
                          error: "#{AdCheck.rule_summary(rules)} This job ad is shown to applicants as soon as it is saved: change the sentence, or write why the work needs it in \"Reason\".")
      end

      flags = AdCheck.call(@text)
      ActiveRecord::Base.transaction do
        before = @job.ad_text
        @job.update!(ad_text: @text, ad_flags: flags)
        # Saving with the tick IS HR's approval of this text.
        @job.update!(ad_approved_at: Time.current, ad_approved_by_id: @actor.id) if live && before != @text
        if before != @text
          changes = { "ad_text" => [before, @text] }
          changes["ad_flags_reason"] = [AdCheck.rule_categories(flags).join(", "), @reason] if live && AdCheck.rule_hit?(flags)
          JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "ad", changes_made: changes, created_at: Time.current)
        end
      end
      Result.new(true, nil, flags)
    end
  end
end
