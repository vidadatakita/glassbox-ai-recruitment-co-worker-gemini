# One candidate's technical test (D60): written when the candidate presses "Start test"
# (TechnicalTests::Start) and completed once by "Send answer" (TechnicalTests::SubmitAnswer).
# The database refuses an attempt on an unapproved version, on another job's version or outside S2,
# a due_at other than started_at + the version's limit, a start after the 48-hour window or on a
# decided participation, and any change to the pinned version, the times, the recorded grace or a
# sent answer (trigger test_attempts_guard; migration 20261010173500). A started version is frozen
# (trigger test_cases_freeze, slice 2).
class TestAttempt < ApplicationRecord
  belongs_to :participation
  delegate :job, to: :participation # the record's company is its job's (BaseController#org_find)
  belongs_to :test_case, class_name: "TechnicalTestCase"
  has_one :review, class_name: "TestReview", dependent: :restrict_with_exception
  # Private storage (plan §d): served only through Staff::TestScoringsController#answer_file as an
  # attachment with nosniff, never through a public ActiveStorage URL.
  has_one_attached :answer_file
  has_many :ai_suggestions, -> { order(:id) }, class_name: "TestAiSuggestion", dependent: :restrict_with_exception

  def answered? = answered_at.present?
  def repo_link? = answer_kind == "repo_link"
  def scan_label = TechnicalTestCase::SCAN_LABELS.fetch(answer_scan_state.to_s, "No file yet")
end
