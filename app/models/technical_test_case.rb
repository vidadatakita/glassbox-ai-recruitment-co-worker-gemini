# One version of a job's technical test (D60, plan §c). Versioned: a change to an approved or
# started version is a new version (n + 1) with a reason. A draft is edited in place by the
# consultant; HR PIC approves it; from then on the database refuses any change (trigger
# test_cases_freeze), and once a candidate has started it (a TestAttempt row) it is frozen even
# before that check (plan §c "the rubric of a started version never changes").
#
# Named TechnicalTestCase, not TestCase: inside views and tests the bare name TestCase resolves to
# ActionView::TestCase / ActiveSupport::TestCase (found 2026-10-10, the step-5 page raised
# "uninitialized constant ActionView::TestCase::DEFAULT_TIME_LIMIT"). The table keeps the plain name.
class TechnicalTestCase < ApplicationRecord
  self.table_name = "test_cases"
  ANSWER_TYPES = { "xlsx" => "Excel (.xlsx)", "docx" => "Word (.docx)", "pdf" => "PDF (.pdf)", "csv" => "CSV (.csv)",
                   "repo_link" => "Repository link (GitHub, GitLab, Bitbucket)" }.freeze
  # repo_link is not a file: it is sent as a URL (TechnicalTests::SubmitAnswer), never uploaded.
  FILE_ANSWER_TYPES = (ANSWER_TYPES.keys - ["repo_link"]).freeze
  # Plan §b/§c, D60 default: 35 minutes per job, at most 60 (the consultant sets it within the max).
  DEFAULT_TIME_LIMIT = 35
  MAX_TIME_LIMIT = 60
  # Plan §d: 20 MB for the consultant's case file (the candidate's answer cap, 10 MB, is slice 3).
  MAX_CASE_FILE_BYTES = 20.megabytes
  SCAN_LABELS = {
    "pending_scan" => "Awaiting antivirus scan", "clean" => "Clean, scanned by antivirus",
    "infected" => "Flagged as malicious by antivirus", "scan_unavailable" => "Not scanned by antivirus"
  }.freeze

  belongs_to :job
  belongs_to :created_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :criteria, -> { order(:position) }, class_name: "TestCaseCriterion", foreign_key: :test_case_id,
                                               dependent: :restrict_with_exception, inverse_of: :test_case
  has_many :attempts, class_name: "TestAttempt", foreign_key: :test_case_id, dependent: :restrict_with_exception
  has_one_attached :case_file

  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :time_limit_minutes, numericality: { only_integer: true, in: 1..MAX_TIME_LIMIT }
  validates :scan_state, inclusion: { in: SCAN_LABELS.keys }, allow_nil: true
  validate :answer_types_known
  # F-03: a version starts as a draft; approval is TestCases::Approve (the database refuses too).
  validate :inserted_as_draft, on: :create

  scope :approved, -> { where.not(approved_at: nil) }

  # The version a candidate starts today: the newest APPROVED one. A newer draft never replaces it
  # until HR approves that draft.
  def self.current_for(job) = job_scope(job).approved.order(version: :desc).first
  def self.latest_for(job) = job_scope(job).order(version: :desc).first
  def self.job_scope(job) = where(job_id: job.id)

  def approved? = approved_at.present?
  def started? = attempts.exists?
  def draft? = !approved?
  def editable? = draft? && !started?
  def weight_total = criteria.sum(&:weight)
  def scan_label = SCAN_LABELS.fetch(scan_state.to_s, "No file yet")
  def file_answer_types = Array(answer_types) & FILE_ANSWER_TYPES
  def repo_link_answer? = Array(answer_types).include?("repo_link")

  # Fingerprint of everything HR PIC reviews before approving (test engine 07 F-02, maker-checker):
  # the case file (blob checksum), instructions, time limit, answer types and every rubric row.
  # The approve form carries the digest of what was on HR's screen; TestCases::Approve refuses when
  # the draft changed since (B-2 lets the consultant edit a draft in place).
  def content_digest
    file = case_file.attached? ? case_file.blob.checksum : nil
    rows = criteria.reload.map { |c| [c.position, c.activity_id, c.activity_text, c.name, c.weight, c.anchor_1, c.anchor_3, c.anchor_5] }
    Digest::SHA256.hexdigest(JSON.generate([file, case_file_blob_id, instructions, time_limit_minutes, Array(answer_types), rows]))
  end

  private

  def inserted_as_draft
    errors.add(:approved_at, "must be empty when a version is created; HR approves it afterwards") if approved_at || approved_by_id
  end

  def answer_types_known
    unknown = Array(answer_types) - ANSWER_TYPES.keys
    errors.add(:answer_types, "unknown: #{unknown.join(', ')}") if unknown.any?
  end
end
