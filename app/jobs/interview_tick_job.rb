# Closes AI interviews that ran out of time (Interviews::Expire.sweep) so S1 can run. Scheduled in
# config/recurring.yml. No arguments, so nothing personal is written to the queue tables (ONP-19).
class InterviewTickJob < ApplicationJob
  queue_as :default

  def perform = Interviews::Expire.sweep
end
