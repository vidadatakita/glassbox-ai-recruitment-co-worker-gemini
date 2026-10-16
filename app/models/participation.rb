class Participation < ApplicationRecord
  ATTENDANCE = %w[pending attended no_show withdrew].freeze

  belongs_to :job_application
  belongs_to :stage
  delegate :job, to: :stage # the record's company is its job's (BaseController#org_find)
  has_many :score_entries, dependent: :restrict_with_exception
  has_many :decisions, dependent: :restrict_with_exception
  has_one :appointment, dependent: :restrict_with_exception
  has_many :objections, dependent: :restrict_with_exception
  # Feature 06, S1 AI screening.
  has_many :screening_results, dependent: :restrict_with_exception
  has_many :screening_attempts, dependent: :restrict_with_exception
  has_many :calibration_judgements, dependent: :restrict_with_exception
  has_many :screening_reviews, dependent: :restrict_with_exception
  # Feature 09 (D51 B): the payload versions waiting for, or carrying, a person's release.
  has_many :ai_releases, dependent: :restrict_with_exception
  # AI Builder Cup step 06: the AI's Lanjut / Tidak Lanjut, and the HR PIC's choice that moves on.
  has_many :stage_recommendations, dependent: :restrict_with_exception
  has_one :progression_choice, dependent: :restrict_with_exception
  has_many :interviewer_invites, dependent: :restrict_with_exception

  # Blueprint §2.1 Participation "screening state" and §4.3. NULL = screening not asked for.
  SCREENING_STATES = {
    "queued" => "Queued for screening", "done" => "Screening done",
    "screening_failed" => "Screening failed", "cv_unreadable" => "CV unreadable",
    # Feature 09 (D51 B): prepared and redacted, waiting for a reviewer to release it ("Send to
    # Gemini"); and declined by the reviewer, so the S1 decision is made by hand.
    "awaiting_release" => "Awaiting review", "not_sent" => "Not sent, decide by hand"
  }.freeze

  validates :attendance, inclusion: { in: ATTENDANCE }
  validates :screening_state, inclusion: { in: SCREENING_STATES.keys }, allow_nil: true

  # An application entering an AI stage is offered to the screening queue once the row is
  # committed (the CV is attached in the same transaction, so it exists by then). Screening::Enqueue
  # applies every gate: consent, knockout, AI active, AI stage; for any other participation it does
  # nothing.
  after_create_commit { Screening::Enqueue.call(self) }

  # Mean of every interviewer's current entry; superseded entries never count.
  def current_score
    values = score_entries.current.pluck(:value)
    values.empty? ? nil : Scoring::StageScore.combine(values)
  end

  def current_decision
    decisions.current.order(:decided_at, :id).last
  end
end
