# Runs ApplicationDrafts::Purge: deletes unsubmitted three-step application drafts (personal details
# and CV without an application) once the vacancy's portal is closed. Scheduled in
# config/recurring.yml. No arguments, so nothing personal is written to the queue tables.
class ApplicationDraftPurgeJob < ApplicationJob
  queue_as :default

  def perform = ApplicationDrafts::Purge.call
end
