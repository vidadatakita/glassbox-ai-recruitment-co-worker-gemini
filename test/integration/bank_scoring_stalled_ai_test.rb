require "test_helper"

# A lost AI rating run (job killed by a restart, a console that exits) leaves the draft at "pending"
# with no error. After ApplicationDraft::AI_STUCK_AFTER the board offers "Ask the AI again", and the
# retry is accepted; before that, it is not.
class BankScoringStalledAiTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include BankFlowHelpers

  test "a run stuck at pending can be retried only after the stall time" do
    draft = applicant!("stalled@uji.example", mc_right: 2)
    young = 2.minutes.ago.change(usec: 0)
    draft.update_columns(ai_status: "pending", updated_at: young)
    sign_in_as @manager

    get staff_job_bank_scorings_path(@job)
    assert_select "form[action$='/retry-ai']", 0, "control: a run that is still young shows no retry"
    post staff_job_bank_scoring_retry_path(@job, draft)
    assert_equal young, draft.reload.updated_at, "control: a young pending run is not restarted"

    draft.update_columns(updated_at: (ApplicationDraft::AI_STUCK_AFTER + 1.minute).ago)
    get staff_job_bank_scorings_path(@job)
    assert_select "form[action$='/retry-ai']", 1
    assert_includes response.body, "has not finished after 10 minutes"
    assert_includes response.body, "failed or stalled"

    assert_enqueued_with(job: BankAnswerAiRateJob, args: [draft.id]) { post staff_job_bank_scoring_retry_path(@job, draft) }
    assert_redirected_to staff_job_bank_scorings_path(@job)
    assert_equal "pending", draft.reload.ai_status
    assert_operator draft.updated_at, :>, 1.minute.ago, "the retry restarts the stall clock"
    refute draft.ai_retryable?
  end

  test "a submit through the form starts the stall clock" do
    draft = applicant!("clock@uji.example", mc_right: 1)
    assert_equal "pending", draft.reload.ai_status
    assert_operator draft.updated_at, :>, 1.minute.ago
    refute draft.ai_retryable?
    assert draft.ai_retryable?(Time.current + ApplicationDraft::AI_STUCK_AFTER + 1.second)
  end
end
