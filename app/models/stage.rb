class Stage < ApplicationRecord
  CODES = %w[S1 S2 S3 S4 S5 RC].freeze
  SOURCES = %w[ai scorecard manual_or_import check].freeze
  STATUSES = %w[draft open closed].freeze
  LOCKED_FIELDS = %w[weight threshold].freeze
  # D60: on a package that runs both S1 and S2, the two are one gate "Seleksi CV dan Tes Teknis"
  # (Briefs::SyncStages sets it). They open together (Gates::Open) and close together
  # (Gates::Close); the database refuses anything else at commit (trigger stages_gate_status_together).
  GATES = { "screening" => "CV screening and technical test" }.freeze

  belongs_to :job
  has_many :participations, dependent: :restrict_with_exception
  has_many :stage_changes, dependent: :restrict_with_exception

  validates :code, inclusion: { in: CODES }
  validates :score_source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :weight, numericality: { in: 0..100 }
  validates :threshold, numericality: { in: 0..100 }
  validates :gate, inclusion: { in: GATES.keys }, allow_nil: true
  validate :locked_fields_unchanged
  validate :lifecycle_moves_forward_only

  def locked?
    opened_at_was.present?
  end

  def gated? = gate.present?

  # Every stage of this stage's gate, S1 first; just this stage when it has no gate.
  def gate_members
    gated? ? job.stages.where(gate:).order(:code).to_a : [self]
  end

  # Only Stages::ChangeThreshold calls this. It writes the StageChange record and
  # re-decides threshold-based decisions in the same transaction (rule 3).
  def unlock_for_change
    @unlocked = true
    yield
  ensure
    @unlocked = false
  end

  # Only Stages::Close calls this: closing is refused while anyone is undecided (§3.4), so a
  # plain update(status: "closed") must not be able to skip that check (test engine F-05).
  def allow_close
    @closing = true
    yield
  ensure
    @closing = false
  end

  private

  # §3.4: draft -> open -> closed, nothing else. opened_at is what locks weight and threshold
  # (rule 3), so it can be set once and never cleared or moved; otherwise clearing it, or
  # reverting to draft, would unlock the stage without a StageChange (test engine F-01, F-02).
  # "open" without opened_at would be an unlocked open stage (F-03). The database enforces the
  # same rules (trigger stages_lifecycle), because a model can be bypassed.
  def lifecycle_moves_forward_only
    if opened_at_was.present? && will_save_change_to_opened_at?
      errors.add(:opened_at, "cannot change once the stage has opened")
    end
    errors.add(:opened_at, "is required for an open or closed stage") if status != "draft" && opened_at.nil?
    return unless will_save_change_to_status?

    allowed = { "draft" => %w[open], "open" => %w[closed] }.fetch(status_was.to_s, [])
    allowed = %w[draft open closed] if new_record?
    errors.add(:status, "cannot move from #{status_was} to #{status}") unless allowed.include?(status)
    errors.add(:status, "is closed only through Stages::Close") if status == "closed" && !@closing && !new_record?
  end

  # Rule 3: once a stage has opened, its weight and threshold are frozen, so nobody can move
  # the line after seeing the scores. The save that OPENS the stage is allowed through,
  # because opened_at_was is still nil at that moment.
  def locked_fields_unchanged
    return unless locked? && !@unlocked

    LOCKED_FIELDS.each do |field|
      errors.add(field, "is locked since the stage opened") if will_save_change_to_attribute?(field)
    end
  end
end
