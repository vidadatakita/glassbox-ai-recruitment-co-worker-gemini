require "test_helper"

# ONP-19 / 2026-10-10 finding: a candidate's status token, offer code and personal fields never
# reach the log. Asserted on the real log output of real requests, not on configuration.
class LogRedactionTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @io = StringIO.new
    @old_logger = Rails.logger
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(@io))
    Rails.logger = logger
    ActionController::Base.logger = logger
    @job = portal_job
    open_portal(@job)
    @application, @token = submit!(@job, name: "Rina Pratiwi", phone: "081234567890")
  end

  teardown do
    Rails.logger = @old_logger
    ActionController::Base.logger = @old_logger
  end

  test "the status token is masked in the request log line" do
    get candidate_status_path(@token)
    post candidate_status_unlock_offer_path(@token), params: { code: "123456" }
    log = @io.string
    assert_includes log, "/status/[FILTERED]", "the log must still show which page was hit"
    refute_includes log, @token
    refute_includes log, "123456", "the offer code"
  end

  test "a submission's personal fields are filtered from the parameters log" do
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
                                                 lamaran: application_params(@job, name: "Budi Santoso", phone: "089900001111").except(:knockout, :cv) }
    log = @io.string
    assert_match(/Parameters:/, log, "the parameters line must be in the log, or this test proves nothing")
    refute_includes log, "Budi Santoso"
    refute_includes log, "089900001111"
  end
end
