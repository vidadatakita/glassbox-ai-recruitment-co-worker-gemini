module AiReleases
  # "Hapus bagian": the reviewer removes whole CV lines from the text before release. The result is
  # a NEW version (the old one stays, append-only) in which each chosen line is replaced by the
  # redaction marker [REDACTED]; nothing is ever added, and the requirements part is never touched.
  # The removed text is not copied again: it stays in the superseded version, and the new version
  # records who cut, which line numbers, and the SHA-256 of the removed lines. The residual check
  # runs again on the new CV part, so the screen and the release rule see the current findings.
  class Cut
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(release:, user:, line_numbers:)
      @release = release
      @user = user
      @numbers = Array(line_numbers).map { |n| Integer(n, exception: false) }.compact.uniq.sort
    end

    def call
      AiReleases.authorize!(@release, @user)
      AiReleases.actionable!(@release)
      raise Refused, "Select at least one line to delete." if @numbers.empty?
      raise Refused, "Only CV lines can be deleted." unless @numbers.all? { |n| @release.cv_range.cover?(n) }

      raise Refused, "This text has been erased because the retention period ended or consent was withdrawn." if @release.erased?

      lines = @release.lines
      # A line that is already [REDACTED] is not a cut: the database requires cut_line_numbers to be
      # exactly the lines that change (F09-02).
      @numbers = @numbers.reject { |n| lines[n] == Screening::Redactor::MARK }
      raise Refused, "The selected lines are already deleted." if @numbers.empty?

      removed = @numbers.map { |n| lines[n] }

      @numbers.each { |n| lines[n] = Screening::Redactor::MARK }
      payload = lines.join("\n")
      cv_part = lines[@release.cv_range].join("\n")
      names = [@release.participation.job_application.candidate&.name]
      AiRelease.create!(
        participation: @release.participation, job: @release.job, payload_kind: @release.payload_kind,
        payload_text: payload, payload_sha256: AiRelease.digest(payload),
        cv_line_start: @release.cv_line_start, cv_line_end: @release.cv_line_end,
        rubric_digest: @release.rubric_digest, source_sha256: @release.source_sha256,
        residual_categories: Screening::ResidualCheck.findings(cv_part, names:),
        supersedes: @release, cut_by: @user, cut_line_numbers: @numbers,
        cut_sha256: AiRelease.digest(removed.join("\n")), created_at: Time.current
      )
    end
  end
end
