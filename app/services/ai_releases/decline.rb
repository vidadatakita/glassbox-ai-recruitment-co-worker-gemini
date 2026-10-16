module AiReleases
  # "Tidak dikirim — putuskan manual": the reviewer decides this text will not go to the AI. A note
  # is required (why). The kind's handler moves the item to its manual path; for a CV that is the
  # state not_sent, and the S1 decision is then made by hand.
  class Decline
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(release:, user:, note:)
      @release = release
      @user = user
      @note = note.to_s.strip
    end

    def call
      AiReleases.authorize!(@release, @user)
      AiReleases.actionable!(@release)
      raise Refused, "Write the reason why this text is not sent." if @note.empty?

      handler = AiReleases.handler_for(@release)
      ActiveRecord::Base.transaction do
        action = AiReleaseAction.create!(ai_release: @release, action: "declined", actor: @user, note: @note,
                                         created_at: Time.current)
        handler.after_decline(@release)
        action
      end
    end
  end
end
