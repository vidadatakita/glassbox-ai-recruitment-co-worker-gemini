module TechnicalTests
  # "Send answer" (plan §b, §d): stores the candidate's one answer, final: a file, or (for a version
  # that allows "repo_link") a link to the candidate's repository on GitHub, GitLab or Bitbucket.
  # The link is checked by shape only and NEVER fetched here (no server-side request to a
  # candidate-supplied URL); the reviewer opens it. The database checks the same shape.
  #
  # Checked, in this order, nothing written on any refusal:
  #   - the test was started and has no answer yet (one answer, final);
  #   - the server's clock is at or before due_at + grace (the recorded grace, 2 minutes);
  #   - the file by CONTENT, with the same inspection as the case file (TestCases::FileInspection):
  #     only the types this version allows, the detected kind must match the extension, no macros,
  #     ActiveX, OLE embeddings or external links, at most 10 MB (MAX_ANSWER_BYTES, passed
  #     explicitly: the inspection's own default is the case file's 20 MB);
  #   - the antivirus seam (TestCases::FileScan): "infected" refuses; with no antivirus installed the
  #     state is "scan_unavailable" and staff see "Not scanned by antivirus" before downloading.
  # Then, in one transaction: private blob, attachment, the answer columns, and attendance
  # "attended" (a ScoreEntry and a threshold Decision both need an attended participation).
  class SubmitAnswer
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    # Same shape as the database check (migration AllowRepoLinkAnswers): owner/repo, optional path.
    REPO_URL = %r{\Ahttps://(github\.com|gitlab\.com|bitbucket\.org)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/\S*)?\z}
    MAX_URL_LENGTH = 300

    def initialize(application:, file: nil, url: nil, now: Time.current)
      @application = application
      @file = file
      @url = url.to_s.strip.presence
      @now = now.floor(6)
    end

    def call
      participation = TechnicalTests.participation_for(@application)
      refuse!("This vacancy has no technical test.") if participation.nil?
      refuse!("Send a file or a repository link, not both.") if @url && @file.respond_to?(:read)
      refuse!("Choose the answer file first.") unless @url || @file.respond_to?(:read)

      ActiveRecord::Base.transaction do
        participation.lock!
        attempt = TestAttempt.lock.find_by(participation_id: participation.id)
        check!(attempt)
        if @url
          store_link!(attempt)
        else
          kind = inspect!(attempt.test_case)
          store!(attempt, kind)
        end
        participation.update!(attendance: "attended")
        attempt
      end
    end

    private

    def check!(attempt)
      refuse!("This application has been withdrawn.") if @application.consent_withdrawn_at.present?
      refuse!("The technical test has not been started.") if attempt.nil?
      refuse!("Your answer has already been sent. The answer can be sent only once.") if attempt.answered_at
      return if @now <= TechnicalTests.answer_deadline(attempt)

      refuse!("The technical test time is up. The answer can no longer be sent.")
    end

    def store_link!(attempt)
      refuse!("This test does not accept a repository link; upload an answer file.") unless attempt.test_case.repo_link_answer?
      unless @url.length <= MAX_URL_LENGTH && @url.match?(REPO_URL)
        refuse!("The link must be a repository address https://github.com/..., https://gitlab.com/... or https://bitbucket.org/... (owner/repo-name).")
      end

      attempt.update!(answered_at: @now, answer_kind: "repo_link", answer_url: @url)
    end

    def inspect!(version)
      refuse!("This test asks for a repository link, not a file.") if version.file_answer_types.empty?

      inspection = TestCases::FileInspection.call(io: @file, filename: @file.original_filename,
                                                  allowed: version.file_answer_types, max_bytes: TechnicalTests::MAX_ANSWER_BYTES)
      refuse!(inspection.problems.first) unless inspection.ok?

      active_content!(inspection.kind)
      inspection.kind
    end

    # Answers are opened by staff on their own computers, so content that ACTS when opened is refused
    # on top of the shared inspection (engine-07 probe, relayed by the slice 1-2 fix work 18:1x):
    #   - PDF: JavaScript, actions run on open, launch, embedded files. A plain-text scan of the raw
    #     bytes; a name written in hex escapes (/J#61vaScript) or inside a compressed object stream is
    #     NOT caught (recorded as an open item; a real PDF parser or the antivirus adapter closes it).
    #   - CSV: a cell that Excel would evaluate as a formula (DDE). Every cell, quoted or not, is
    #     normalised first (UTF-8 BOM removed, NFKC so full-width ＝ becomes =, leading spaces and
    #     quotes stripped); it is refused when its first character is = + - @ TAB or CR, UNLESS the
    #     whole cell is exactly a number ("-8", "-8.5", "-1.234,56"). Matched whole, never as a
    #     prefix: "-2+3+cmd|..." starts like a number and is still refused (engine 07 run 2, F-08).
    PDF_ACTIVE = %r{/(JavaScript|JS|OpenAction|AA|Launch|EmbeddedFile)\b}
    CSV_FORMULA_START = /\A[=+\-@\t\r]/
    CSV_PLAIN_NUMBER = /\A[+-]?\d+(?:[.,]\d+)*\z/

    def active_content!(kind)
      @file.rewind
      bytes = @file.read.to_s.b
      @file.rewind
      if kind == "pdf" && bytes.match?(PDF_ACTIVE)
        refuse!("The PDF file contains a script or an automatic action. Save it again as a plain PDF (Print to PDF), then upload it again.")
      end
      return unless kind == "csv"

      text = bytes.force_encoding("UTF-8").scrub
      formula = text.each_line.any? { |line| line.chomp.split(/[,;]/).any? { |cell| csv_formula?(cell) } }
      refuse!("The CSV file contains a cell starting with =, +, - or @ (read by Excel as a formula). Remove that character, then upload it again.") if formula
    end

    def store!(attempt, kind)
      @file.rewind
      scan = TestCases::FileScan.call(@file)
      refuse!("The answer file was refused: the antivirus detected malicious content.") if scan == "infected"

      @file.rewind
      sha256 = Digest::SHA256.hexdigest(@file.read)
      @file.rewind
      blob = ActiveStorage::Blob.create_and_upload!(io: @file, filename: "jawaban-#{attempt.id}.#{kind}",
                                                    content_type: TestCases::SaveVersion::CONTENT_TYPES.fetch(kind), identify: false)
      attempt.answer_file.attach(blob)
      attempt.update!(answered_at: @now, answer_blob_id: blob.id, answer_kind: kind, answer_sha256: sha256,
                      answer_bytes: blob.byte_size, answer_scan_state: scan)
    end

    def csv_formula?(cell)
      value = cell.delete("\uFEFF").unicode_normalize(:nfkc).sub(/\A[ "']+/, "").sub(/["' ]+\z/, "")
      value.match?(CSV_FORMULA_START) && !value.match?(CSV_PLAIN_NUMBER)
    end

    def refuse!(message) = raise(Refused, message)
  end
end
