module Screening
  # Decides whether a participation may go to the AI, and queues it (blueprint §4.1 steps 1-2).
  #
  # The gates, in order. Any one closed -> nothing is queued, nothing is sent, no state is
  # written, and the reason is returned (the job page shows the reasons that need a person):
  #   not_ai_stage   the stage's score source is not "ai"
  #   no_candidate   a bare application (scoring tests) has no person and no CV
  #   no_consent     D15: no recorded consent -> the AI is never called. Imported CVs (board-only
  #                  applications) would wait here as awaiting_consent; that import flow is not
  #                  built yet (feature record 06 §8), so today only Lamar applications arrive, and
  #                  each carries consent (database check job_applications_consent_recorded).
  #   withdrawn      consent withdrawn or application withdrawn
  #   knocked_out    rule 16: a knockout "tidak" is eliminated by rule; the AI is never called
  #   decided        a decision already exists; screening would change nothing
  #   stage_closed   a closed stage takes manual decisions only (D37)
  #   no_cv          nothing to read
  #
  # No longer a gate here (D51, feature 09): the API key. Without a key a CV is still prepared
  # LOCALLY (evidence sections, redaction, residual check; nothing leaves the server) and waits in
  # "Menunggu pemeriksaan"; the key is checked when a reviewer presses "Kirim ke AI" and again just
  # before the call (Screening::ReleaseGate). The job page and Antrean Kerja still say "Screening AI
  # belum aktif. Kunci API belum diatur." and nothing is sent or scored. :ai_off is still a symbol
  # callers may compare with; blocked_reason no longer returns it.
  class Enqueue
    RERUNNABLE = %w[screening_failed].freeze

    def self.call(participation, rerun: false) = new(participation).call(rerun:)

    def self.blocked_reason(participation) = new(participation).blocked_reason

    def initialize(participation)
      @participation = participation
      @application = participation.job_application
      @stage = participation.stage
    end

    # rerun: true also re-queues a failed screening and a finished one whose rubric has changed
    # since (staff action "Mulai screening" on the job page). Without it only a participation that
    # was never screened is queued, so a second click or a second callback queues nothing twice.
    def call(rerun: false)
      reason = blocked_reason
      return reason if reason

      state = @participation.screening_state
      # In the automatic mode a CV still waiting for a reviewer (prepared under the release-first
      # rule, or held for a residual finding) may be run again: it goes to the AI when now clean.
      waiting = state == "awaiting_release" && !Config.review_before_ai?
      allowed = state.nil? || (rerun && (RERUNNABLE.include?(state) || stale_done?(state) || stale_release?(state) || waiting))
      return :already unless allowed

      @participation.update!(screening_state: "queued", screening_failure: nil, screening_failure_detail: nil,
                             screening_state_at: Time.current)
      ScreenParticipationJob.perform_later(@participation.id)
      :queued
    end

    def blocked_reason
      return :not_ai_stage unless @stage.score_source == "ai"
      return :no_candidate if @application.candidate_id.nil?
      return :no_consent if @application.consent_at.nil?
      return :withdrawn if @application.consent_withdrawn_at.present? || @application.status == "withdrawn"
      return :knocked_out if @application.knocked_out?
      return :decided if @participation.current_decision
      return :stage_closed if @stage.status == "closed"
      return :no_cv if @application.cv_text.blank? && !@application.cv.attached?

      nil
    end

    private

    # Waiting for the reviewer, but the rubric changed since the text was prepared: prepare it again
    # (the old version can no longer be released; ReleaseGate checks the same digests).
    def stale_release?(state)
      return false unless state == "awaiting_release"

      release = AiRelease.latest_for(@participation)
      release.nil? || release.rubric_digest != Rubric.for(@stage.job).digest
    end

    def stale_done?(state)
      return false unless state == "done"

      result = @participation.screening_results.order(:id).last
      result.nil? || result.stale?(Rubric.for(@stage.job).digest)
    end
  end
end
