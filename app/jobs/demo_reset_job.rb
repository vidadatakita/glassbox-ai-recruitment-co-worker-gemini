# A5: the nightly reset of the demo workspace (config/recurring.yml, 20:00 UTC = 03:00 WIB). The
# service refuses to run outside DEMO_MODE, so scheduling this job on a non-demo install is harmless
# and logged. DEMO_RESET=off pauses this schedule only (the team's claims check and the video
# recording must not lose the workspace mid-scene); `bin/rails glassbox:demo:reset` still runs on
# demand. No retry: a failed reset is better left for a person to read in the morning than repeated
# against a half-dropped schema.
class DemoResetJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform
    if Glassbox::Settings.demo_reset_paused?
      Rails.logger.warn("[demo_reset] skipped: DEMO_RESET=off (scheduled reset paused)")
      return
    end

    result = Demo::Reset.call
    Rails.logger.warn("[demo_reset] skipped: #{result.error}") unless result.success?
  end
end
