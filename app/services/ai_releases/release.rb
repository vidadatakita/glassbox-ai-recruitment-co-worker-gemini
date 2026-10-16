module AiReleases
  # "Kirim ke AI": the reviewer releases one version. Requires the tick "Saya sudah memeriksa teks
  # ini dan tidak ada data pribadi yang terlihat" and the digest of the version the reviewer saw (a
  # hidden field), so a version that changed between opening and pressing cannot be released by
  # mistake. Refused while the version has residual-check findings (fail closed, ADR 0004) or the
  # API key is not set (the text would wait anyway; the screen says why). Records who, when and the
  # SHA-256; the sender later sends exactly this text (Screening::ReleaseGate).
  class Release
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(release:, user:, confirmed:, seen_sha256:)
      @release = release
      @user = user
      @confirmed = confirmed.to_s == "1"
      @seen = seen_sha256.to_s
    end

    def call
      AiReleases.authorize!(@release, @user)
      AiReleases.actionable!(@release)
      raise Refused, "This text has been erased because the retention period ended or consent was withdrawn." if @release.erased?
      raise Refused, "Tick the statement that you have checked this text." unless @confirmed
      raise Refused, "The text changed since the page was opened. Check the latest version again." unless @seen == @release.payload_sha256
      raise Refused, "The stored text changed since it was prepared. Not sent; report this to the admin." unless @release.digest_intact?
      raise Refused, "Personal data is still detected. Delete the lines marked red, or choose Not sent." if @release.residual?

      handler = AiReleases.handler_for(@release)
      handler.releasable!(@release)
      action = ActiveRecord::Base.transaction do
        handler.after_release(@release)
        AiReleaseAction.create!(ai_release: @release, action: "released", actor: @user, checked: true,
                                payload_sha256: @release.payload_sha256, created_at: Time.current)
      end
      handler.after_commit_release(@release)
      action
    end
  end
end
