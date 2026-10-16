# frozen_string_literal: true

module Briefs
  # Saves the job ad and checks it (Briefs::AdCheck), recording the change like every brief step.
  # After HR has approved the ad, only HR edits it, and every save needs the tick (confirmed): the
  # text shows on the Lamar page at once, so saving it IS HR's approval of the new text.
  class SaveAd
    Result = Data.define(:ok, :error, :flags) do
      def ok? = ok
    end

    def self.call(job:, actor:, text:, confirmed: false) = new(job:, actor:, text:, confirmed:).call

    def initialize(job:, actor:, text:, confirmed: false)
      @job = job
      @actor = actor
      @text = text.to_s.gsub("\r\n", "\n").strip
      @confirmed = confirmed
    end

    def call
      return Result.new(false, "An approved job ad can only be changed by HR.", @job.ad_flags) unless @job.ad_writable_by?(@actor)
      return Result.new(false, "Write the job ad first.", []) if @text.empty?
      live = @job.ad_approved_at.present?
      if live && !@confirmed
        return Result.new(false, "Tick \"I have checked this text\": this job ad is already approved, so the text you save is shown to applicants at once.", [])
      end

      flags = AdCheck.call(@text)
      ActiveRecord::Base.transaction do
        before = @job.ad_text
        @job.update!(ad_text: @text, ad_flags: flags)
        # Saving with the tick IS HR's approval of this text.
        @job.update!(ad_approved_at: Time.current, ad_approved_by_id: @actor.id) if live && before != @text
        if before != @text
          JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "ad",
                                 changes_made: { "ad_text" => [before, @text] }, created_at: Time.current)
        end
      end
      Result.new(true, nil, flags)
    end
  end
end
