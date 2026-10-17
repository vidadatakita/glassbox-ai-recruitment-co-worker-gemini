# One answer in a three-step application's competency test (ApplicationDraft). Saved as typed while
# the timer runs (the trigger draft_answers_guard refuses an answer after the deadline plus the grace,
# after Submit, or to a question that was not drawn). `correct` is filled at Submit for a
# multiple-choice question from the bank's answer key.
class DraftAnswer < ApplicationRecord
  belongs_to :application_draft
  belongs_to :bank_question
end
