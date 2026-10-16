module AiReleases
  # Erases every release text of one application (all kinds, all versions): first an
  # AiReleaseErasure row per version (who, why, when), then payload_text set to NULL in ONE
  # statement. The digest, the actions (who released, when, the released digest) and the cut
  # records stay, so the audit trail survives without the personal text. Kind-generic: D63's stage
  # recommendations erase their release texts through this too.
  #
  # reason: retention_expired (the retention period ended, D32), consent_withdrawn (Pasal 40),
  # no_consent (an imported CV whose consent never came, D16). actor: the user who triggered it, or
  # nil for the system / the candidate's own withdrawal.
  #
  # update_all, not update!: AiRelease is AppendOnly (readonly once persisted) on purpose; the
  # database trigger ai_releases_erase_only permits exactly this statement. One transaction: a
  # refusal erases nothing. Returns the number of versions erased.
  class Erase
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(application:, reason:, actor: nil, note: nil)
      @application = application
      @reason = reason.to_s
      @actor = actor
      @note = note
    end

    def call
      raise ArgumentError, "unknown erasure reason #{@reason.inspect}" unless AiReleaseErasure::REASONS.key?(@reason)

      ActiveRecord::Base.transaction do
        scope = AiRelease.where(participation_id: @application.participations.select(:id)).where.not(payload_text: nil)
        ids = scope.pluck(:id)
        logged = AiReleaseErasure.where(ai_release_id: ids).pluck(:ai_release_id)
        (ids - logged).each do |id|
          AiReleaseErasure.create!(ai_release_id: id, actor: @actor, reason: @reason, note: @note, created_at: Time.current)
        end
        scope.update_all(payload_text: nil)
      end
    end
  end
end
