# One version of a vacancy's competency test bank (FLOW §7, 17 Oct 2026), beside the uploaded case
# file (TechnicalTestCase). Three steps: the HR Admin builds it in brief step 5 (draft), confirms the
# work is done (submitted: the questions are locked), and the HR Manager approves it or returns it to
# draft with a reason. An approved version is final (trigger question_banks_freeze); a change is
# version n + 1 with a reason. Each applicant draws technical_draw + role_draw questions
# (slice B); a section must hold at least twice its draw (MIN_FACTOR).
class QuestionBank < ApplicationRecord
  SECTIONS = { "technical" => "Technical competency", "role" => "Role competency" }.freeze
  DEFAULT_TECHNICAL_DRAW = 5
  DEFAULT_ROLE_DRAW = 3
  DEFAULT_TIME_LIMIT = 30
  MAX_TIME_LIMIT = 60
  MAX_DRAW = 20
  # The bank holds at least twice what one applicant draws, so nobody sees more than half a section
  # (the 10 -> 5 and 6 -> 3 defaults). The trigger checks the same factor; change both together.
  MIN_FACTOR = 2

  belongs_to :job
  belongs_to :created_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :submitted_by, class_name: "User", optional: true
  has_many :questions, -> { order(:position) }, class_name: "BankQuestion", dependent: :restrict_with_exception,
                                                 inverse_of: :question_bank

  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :technical_draw, :role_draw, numericality: { only_integer: true, in: 1..MAX_DRAW }
  validates :time_limit_minutes, numericality: { only_integer: true, in: 1..MAX_TIME_LIMIT }

  scope :approved, -> { where.not(approved_at: nil) }

  # The bank applicants draw from today: the newest APPROVED version. A newer draft never replaces it
  # until the HR Manager approves that draft.
  def self.current_for(job) = where(job_id: job.id).approved.order(version: :desc).first
  def self.latest_for(job) = where(job_id: job.id).order(version: :desc).first

  def approved? = approved_at.present?
  def submitted? = submitted_at.present? && !approved?
  def draft? = submitted_at.nil?
  # Only a draft is edited; a submitted bank is returned to draft first, an approved one gets a new version.
  def editable? = draft?
  def state = approved? ? "approved" : (submitted? ? "submitted" : "draft")

  def draw_for(section) = section == "technical" ? technical_draw : role_draw
  def minimum_for(section) = draw_for(section) * MIN_FACTOR
  def questions_in(section) = questions.select { |q| q.section == section }

  # Fingerprint of everything the HR Manager reviews before approving: the draw rule, the time limit
  # and every question. The approve form carries the digest of what was on the screen;
  # TestCases::ApproveBank refuses when the draft changed since (the HR Admin may still be editing).
  def content_digest
    rows = questions.reload.map do |q|
      [q.position, q.section, q.kind, q.activity_id, q.activity_text, q.competency_id, q.competency_name, q.prompt,
       q.options, q.correct_index, q.anchor_1, q.anchor_3, q.anchor_5]
    end
    Digest::SHA256.hexdigest(JSON.generate([technical_draw, role_draw, time_limit_minutes, rows]))
  end
end
