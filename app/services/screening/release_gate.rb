module Screening
  # D51 (feature 09): the gate between a CV and the Gemini API. Screening::Run calls it in place of
  # the old redact-and-send step; it returns the AiRelease to send, or nil when the CV must wait
  # for a person.
  #
  # Pass 1, no usable release yet (the CV is new, the rubric or the CV text changed, or the last
  # release was already used):
  #   A  keep only the evidence sections (Screening::EvidenceSections); none -> "Perlu cek manual"
  #      (screening_failed, no_evidence_section), nothing sent;
  #   C  redact (Screening::Redactor, unchanged), evidence floor (too_little_text, unchanged), and
  #      the fail-closed residual check (Screening::ResidualCheck, unchanged). A residual finding no
  #      longer fails the screening outright: it is stored on the release and the database refuses
  #      to release that version, so the reviewer must cut the line or decline. Nothing with a
  #      residual shape can be sent, exactly as before;
  #   B  store the exact request text as an AiRelease and stop: state awaiting_release
  #      ("Menunggu pemeriksaan"). No API call.
  #
  # Pass 2, the latest release was released by a reviewer and not yet used:
  #   - the rubric and the CV text must be the ones it was prepared from, else it is outdated and a
  #     new version goes back to the reviewer (a released text is never "updated");
  #   - the stored text must still hash to the released digest (row and action), else the release is
  #     refused and the CV re-queued for release ("release_mismatch" in the log and the attempt
  #     history);
  #   - the API key must be set, else "Screening gagal: kunci API belum diatur" (retry with "Mulai
  #     screening" once the key is set; the same released text is then sent).
  # Retries of the same released text (timeouts, a malformed answer, "Mulai screening" after a
  # failure) reuse the release: it is the same text the person approved. Any change to the text is
  # a new release.
  #
  # AI_SCREENING_REVIEW=auto (the default since 2026-10-10, owner's decision: "the AI screens first,
  # people decide on the result"): the same preparation (A, C), and when the residual check finds
  # nothing, the prepared text goes to the AI at once as an AutoRelease, without a stored release
  # or a person in between. A residual finding still holds the CV for a reviewer, exactly as above.
  # Eliminations and a sample of passes are still reviewed after the AI (Screening::Finalize).
  class ReleaseGate
    KIND = "cv_screening".freeze
    # What the automatic mode sends: the same shape Run reads from an AiRelease.
    AutoRelease = Data.define(:payload_text, :payload_sha256, :cv_part)
    NO_EVIDENCE = "No experience/education section found".freeze

    def self.call(participation, text:, rubric:, names:, attempt: 1) = new(participation, text:, rubric:, names:, attempt:).call

    def initialize(participation, text:, rubric:, names:, attempt: 1)
      @participation = participation
      @attempt = attempt
      @text = text
      @rubric = rubric
      @names = names
      @source_sha = AiRelease.digest(text)
    end

    def call
      if !Config.review_before_ai? && (auto = auto_release)
        return auto
      end

      latest = AiRelease.latest_for(@participation, KIND)
      if latest&.released? && !latest.consumed?
        return sendable(latest) if fresh?(latest)

        Rails.logger.info("[ai_release] release=#{latest.id} outdated (rubric or CV changed); new version prepared")
      end
      prepare(latest)
      nil
    end

    # The release's text no longer matches its digest at send time (Errors::ReleaseMismatch from
    # AiClient#judge_released): nothing was sent. A new version goes to the reviewer.
    def requeue!(release, reason)
      Rails.logger.warn("[ai_release] release=#{release.id} refused at send: #{reason}; re-queued for release")
      prepare(nil)
    end

    private

    def fresh?(release) = release.rubric_digest == @rubric.digest && release.source_sha256 == @source_sha

    def sendable(release)
      intact = release.digest_intact? && release.action.payload_sha256 == release.payload_sha256
      clean = ResidualCheck.findings(release.cv_part, names: @names).empty?
      unless intact && clean
        ScreeningAttempt.create!(participation: @participation, attempt: @attempt, outcome: "failed", error_kind: "release_mismatch",
                                 detail: intact ? "residual check findings" : "digest mismatch", created_at: Time.current)
        requeue!(release, intact ? "residual findings" : "digest mismatch")
        return nil
      end
      raise Errors::Permanent.new("config", "API key not configured") unless Config.enabled?

      release
    end

    # The automatic mode: prepared exactly as for a person (evidence sections, redaction, the floor),
    # then sent only when the residual check is clean; otherwise nil, and the CV waits for a person.
    def auto_release
      redacted = redacted_text
      return nil if ResidualCheck.findings(redacted, names: @names).any?
      # A sentence that tries to steer the AI: a person reads it first (Screening::InjectionCheck).
      if InjectionCheck.suspicious?(redacted)
        Rails.logger.warn("[screening] participation=#{@participation.id} held: instruction-like text in the CV")
        return nil
      end
      raise Errors::Permanent.new("config", "API key not configured") unless Config.enabled?

      payload = AiClient.user_content(redacted, @rubric.payload)
      AutoRelease.new(payload_text: payload, payload_sha256: Digest::SHA256.hexdigest(payload.encode("UTF-8")), cv_part: redacted)
    end

    def redacted_text
      evidence = EvidenceSections.keep(@text, groups: CvSections.enabled(company: @participation.stage.job.client_company))
      raise Errors::Permanent.new("no_evidence_section", NO_EVIDENCE) if evidence.nil?

      redacted = Redactor.call(evidence, names: @names).text
      # F-23 (unchanged): never let the AI judge a CV that redaction has emptied.
      raise Errors::Permanent.new("too_little_text", "too little CV content left after redaction") if ResidualCheck.too_little_text?(redacted)

      redacted
    end

    def prepare(latest)
      redacted = redacted_text

      unless reusable?(latest)
        create_release(redacted)
      end
      @participation.update!(screening_state: "awaiting_release", screening_failure: nil, screening_failure_detail: nil,
                             screening_state_at: Time.current)
    end

    # A version still waiting for the reviewer, prepared from the same CV and rubric, is kept as it
    # is: it may carry the reviewer's cuts, which a fresh preparation would silently undo.
    def reusable?(latest)
      latest&.pending? && fresh?(latest)
    end

    def create_release(redacted)
      payload = AiClient.user_content(redacted, @rubric.payload)
      prefix = AiClient.user_content("\u0000", @rubric.payload).split("\u0000").first
      start = prefix.count("\n")
      AiRelease.create!(
        participation: @participation, job: @participation.stage.job, payload_kind: KIND,
        payload_text: payload, payload_sha256: AiRelease.digest(payload),
        cv_line_start: start, cv_line_end: start + redacted.split("\n", -1).size - 1,
        rubric_digest: @rubric.digest, source_sha256: @source_sha,
        residual_categories: ResidualCheck.findings(redacted, names: @names), created_at: Time.current
      )
    end
  end
end
