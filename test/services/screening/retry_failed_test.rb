require "test_helper"

# End-to-end test, 16 Oct 2026, P0: the public demo opens no consultant door, so the HR owner and the
# reviewer retry failed screenings themselves (Screening::Start.retry_failed). Risks hunted: a retry
# that sends again a CV needing a manual check, re-sends a finished CV, reaches a withdrawn
# application, or writes a decision itself; and a button count that differs from what is queued.
class Screening::RetryFailedTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup { @job = screening_job }

  def failed_row(name, kind)
    apply_with_cv!(@job, name:).tap do |p|
      p.update_columns(screening_state: "screening_failed", screening_failure: kind, screening_failure_detail: nil)
    end
  end

  test "only failed rows a new attempt can fix are queued again, through the screening job; no decision is written" do
    # rejected: the HTTP 404 every CV got while the HIGH tier named a model Vertex AI does not serve.
    fixable = %w[rejected api_error refusal unexpected].map { |kind| failed_row("Calon #{kind.camelize}", kind) }
    manual = Screening::Start::NEEDS_CV_TEXT.map { |kind| failed_row("Calon #{kind.camelize}", kind) }
    withdrawn = failed_row("Calon Mundur", "api_error")
    withdrawn.job_application.update_columns(consent_withdrawn_at: Time.current)
    finished = apply_with_cv!(@job, name: "Calon Selesai").tap { |p| p.update_columns(screening_state: "done") }
    clear_enqueued_jobs

    assert_equal fixable.map(&:id).sort, ScreeningBoard.new(@job).retryable.map(&:id).sort, "the button counts what a retry queues"
    queued = Screening::Finalize.stub(:call, ->(*) { flunk "a retry writes no decision" }) { Screening::Start.retry_failed(@job) }

    assert_equal fixable.size, queued
    fixable.each { |p| assert_equal ["queued", nil], [p.reload.screening_state, p.screening_failure], p.job_application.candidate.name }
    manual.each { |p| assert_equal "screening_failed", p.reload.screening_state, "#{p.screening_failure}: needs a pasted text, not a retry" }
    assert_equal "screening_failed", withdrawn.reload.screening_state, "a withdrawn application is never sent"
    assert_equal "done", finished.reload.screening_state, "a finished CV is not sent again"
    assert_enqueued_jobs fixable.size, only: ScreenParticipationJob
    assert_equal 0, Screening::Start.retry_failed(@job), "a second click queues nothing twice"
  end
end
