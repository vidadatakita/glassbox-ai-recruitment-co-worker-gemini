# AI Builder Cup step 07: an interviewer without an account (the hiring manager) invited by the HR
# PIC to score one interview participation from a link (OneTimeLink purpose "interviewer_score").
class InterviewerInvite < ApplicationRecord
  LINK_PURPOSE = "interviewer_score".freeze
  LINK_DAYS = 7

  belongs_to :participation
  belongs_to :issued_by, class_name: "User"
  belongs_to :score_entry, optional: true

  validates :interviewer_name, presence: true

  def submitted? = submitted_at.present?
end
