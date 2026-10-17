# Runs ApplicationDrafts::AiRate for one submitted three-step application, right after Submit (slice C).
# The argument is the draft id only, so nothing personal is written to the queue tables.
class BankAnswerAiRateJob < ApplicationJob
  queue_as :default

  def perform(draft_id)
    draft = ApplicationDraft.find_by(id: draft_id)
    ApplicationDrafts::AiRate.call(draft) if draft
  end
end
