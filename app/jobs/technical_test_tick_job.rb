# Runs TechnicalTests::Tick (D60 slices 3-4): technical-test expiry to no_show, the 24-hour
# reminder, and gate-outcome notices. Scheduled in config/recurring.yml. No arguments, so nothing
# personal is written to the queue tables (ONP-19).
class TechnicalTestTickJob < ApplicationJob
  queue_as :default

  def perform = TechnicalTests::Tick.call
end
