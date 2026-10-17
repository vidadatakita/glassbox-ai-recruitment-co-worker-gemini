# One question in a competency test bank (QuestionBank). A technical question tests one brief
# activity; a role question tests one brief competency. Multiple choice is scored automatically
# (correct_index, 0-based); a written answer is scored against anchors 1/3/5 (slice C). The link to
# the brief row is an id plus a text snapshot, so a later brief edit never changes what an approved
# question tested.
class BankQuestion < ApplicationRecord
  KINDS = { "multiple_choice" => "Multiple choice", "written" => "Short written answer" }.freeze
  SOURCES = { "manual" => "Written by HR", "ai" => "AI draft, reviewed by HR", "import" => "Imported from Excel" }.freeze
  MIN_OPTIONS = 2
  MAX_OPTIONS = 6

  belongs_to :question_bank

  validates :section, inclusion: { in: QuestionBank::SECTIONS.keys }
  validates :kind, inclusion: { in: KINDS.keys }
  validates :source, inclusion: { in: SOURCES.keys }
  validates :prompt, presence: true

  def multiple_choice? = kind == "multiple_choice"
  def written? = kind == "written"
  def technical? = section == "technical"
  def link_text = technical? ? activity_text : competency_name
  def linked? = technical? ? activity_id.present? : competency_id.present?
  def correct_option = multiple_choice? ? options[correct_index] : nil
  def anchors_complete? = [anchor_1, anchor_3, anchor_5].all? { |a| a.to_s.strip.present? }
end
