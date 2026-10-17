require "test_helper"

class InterviewTickJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  test "the tick expires only the due interviews and queues S1 for each" do
    job = screening_job
    Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor: staff_user("admin"))
    due, fresh = with_env({ "AI_SCREENING_REVIEW" => "auto" }) do
      with_ai(FakeGemini.new) do
        a, = submit!(job, email: "a@uji.example", cv: pdf_upload(pdf_with_text(FIXTURE_CV)))
        b, = submit!(job, email: "b@uji.example", cv: pdf_upload(pdf_with_text(FIXTURE_CV)))
        [a.interview, b.interview]
      end
    end
    due.update!(started_at: 31.minutes.ago)
    fresh.update!(started_at: 5.minutes.ago)

    with_env({ "AI_SCREENING_REVIEW" => "auto" }) { with_ai(FakeGemini.new) { InterviewTickJob.perform_now } }

    assert_equal "time_up", due.reload.finish_reason
    assert fresh.reload.open?
    assert_enqueued_jobs 1, only: ScreenParticipationJob
  end
end
