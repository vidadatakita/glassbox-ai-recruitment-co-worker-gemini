require "test_helper"

class Interviews::ExpireTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    switch_ai_interview_on(actor: staff_user("admin"))
    @application = with_env({ "AI_SCREENING_REVIEW" => "auto" }) do
      with_ai(FakeGemini.new) { submit!(@job, cv: pdf_upload(pdf_with_text(FIXTURE_CV))).first }
    end
    @interview = @application.interview
  end

  def expire(now) = with_env({ "AI_SCREENING_REVIEW" => "auto" }) { with_ai(FakeGemini.new) { Interviews::Expire.call(@interview, now:) } }

  test "time_up exactly 30 minutes after the first question, not one second earlier" do
    start = Time.current.change(usec: 0)
    @interview.update!(started_at: start)
    assert_nil expire(start + 30.minutes - 1.second)
    assert @interview.reload.open?
    assert_equal "time_up", expire(start + 30.minutes).finish_reason
  end

  test "never_started after 48 hours without a first question" do
    created = @interview.created_at
    assert_nil expire(created + 48.hours - 1.second)
    assert_equal "never_started", expire(created + 48.hours).finish_reason
  end

  test "a finished interview is left alone and the application form works too" do
    Interviews::Finish.call(@interview, reason: "completed", queue: false)
    assert_nil expire(Time.current + 3.days)
    assert_nil Interviews::Expire.call(@application, now: Time.current + 3.days)
  end
end
