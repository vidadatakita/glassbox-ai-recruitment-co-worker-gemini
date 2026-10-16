# What the job page and Antrean Kerja show about S1 AI screening for one job (feature 06;
# blueprint §4.3: the operator sees every failure on screen, not only in a log).
class ScreeningBoard
  FAILURE_LABELS = {
    "timeout" => "The AI service did not answer in time",
    "connection" => "The connection to the AI service failed",
    "api_error" => "The AI service is having problems",
    "malformed" => "The AI answer did not match the expected format",
    "refusal" => "The AI declined to assess this CV",
    "rejected" => "The AI service rejected the request. Check the credentials and the model name",
    "rubric" => "The vacancy brief is incomplete",
    "personal_data" => "Manual check needed: personal data still detected after redaction, the CV was not sent to the AI",
    "too_little_text" => "Manual check needed: after redaction too little CV text is left to assess, the CV was not sent to the AI",
    "protected_attribute" => "The AI noticed a protected attribute",
    "finalize" => "The AI result is stored, but the rule-based decision could not be recorded. Press Start screening to retry (the CV is not sent again)",
    "cv_file" => "The CV file could not be read from storage",
    # Feature 09 (D51).
    "no_evidence_section" => "Manual check needed: the CV was not sent to the AI",
    "config" => "The text was released by the reviewer but not sent. Press Start screening once the credentials are configured",
    "release_mismatch" => "The text to be sent differed from the released text and was not sent. A new version is prepared for review",
    "unexpected" => "Screening stopped because of a system fault, not because of the CV. Try \"Start screening\" again; if it repeats, contact the admin"
  }.freeze

  # Shown when the AI is off (D50). One sentence for the reason, one for the consequence.
  OFF_MESSAGE = "AI screening is off. No credentials are configured.".freeze

  attr_reader :job

  def self.failure_label(participation)
    label = FAILURE_LABELS.fetch(participation.screening_failure.to_s, "Screening failed")
    # A system fault's detail is a Ruby class name (KeyError...): kept in the log and the attempt
    # history for the admin, never shown to people who cannot act on it.
    detail = participation.screening_failure_detail.presence unless participation.screening_failure.to_s == "unexpected"
    detail ? "#{label} (#{detail})" : label
  end

  def initialize(job)
    @job = job
  end

  def stage = @stage ||= job.stages.find_by(code: "S1", score_source: "ai")
  def applicable? = !stage.nil?
  def enabled? = Screening::Config.enabled?

  def participations
    @participations ||= stage ? stage.participations.includes(job_application: :candidate).order(:id).to_a : []
  end

  def in_state(state) = participations.select { |p| p.screening_state == state }
  def failed = in_state("screening_failed")
  # Stored result, but the automatic decision step raised afterwards (F-14). Never re-sent.
  def finalize_errors = done.select { |p| p.screening_failure == "finalize" }
  def unreadable = in_state("cv_unreadable")
  def queued = in_state("queued")
  def done = in_state("done")
  # Feature 09 (D51 B): prepared texts waiting for a reviewer, and texts the reviewer declined.
  def awaiting_release = in_state("awaiting_release").select { |p| Screening::Enqueue.blocked_reason(p).nil? }
  def not_sent = in_state("not_sent")

  # Applications the AI has not been asked about yet although they could be screened: nonzero
  # while the key is missing, or for applications that arrived before it was set.
  def waiting
    participations.select { |p| p.screening_state.nil? && Screening::Enqueue.blocked_reason(p).in?([nil, :ai_off]) }
  end

  def calibration = @calibration ||= Screening::Calibration.new(job)
  def review_queue = @review_queue ||= Screening::ReviewQueue.new(job, calibration:)
  def to_review = review_queue.for_review
  def calibrated? = calibration.passed?

  def stale
    by_id = participations.index_by(&:id)
    ScreeningResult.current_for(by_id.keys).select do |r|
      r.stale?(calibration.digest) && by_id[r.participation_id].current_decision.nil?
    end
  end
end
