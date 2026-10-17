# Runs ApplicationDrafts::AutoSubmit: sends the three-step applications whose test time ran out with the
# tab closed. Scheduled in config/recurring.yml (every 5 minutes). No arguments, so nothing personal is
# written to the queue tables. The counts are logged every run; a refused draft is logged at warn level
# by the service with its id and reason.
class ApplicationDraftAutoSubmitJob < ApplicationJob
  queue_as :default

  def perform
    result = ApplicationDrafts::AutoSubmit.call
    Rails.logger.info("[auto_submit] submitted=#{result.submitted} skipped=#{result.skipped} failed=#{result.failed}")
    result
  end
end
