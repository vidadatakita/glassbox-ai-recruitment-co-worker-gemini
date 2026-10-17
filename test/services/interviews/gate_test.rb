require "test_helper"

# The AI interview holds S1: with the switch on, a new Lamar application gets an open Interview and
# Screening::Enqueue refuses (:interview_pending) until Interviews::Finish.
class Interviews::GateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup { @job = screening_job }

  def switch_on = switch_ai_interview_on(actor: staff_user("admin"))
  def auto(&) = with_env({ "AI_SCREENING_REVIEW" => "auto" }, &)

  def apply(fake = FakeGemini.new, **overrides)
    auto do
      with_ai(fake) do
        application, = submit!(@job, name: "Rina Pratiwi", email: "rina-#{SecureRandom.hex(3)}@uji.example",
                                     cv: pdf_upload(pdf_with_text(FIXTURE_CV)), **overrides)
        application
      end
    end
  end

  test "switch on: a new application gets an open interview and S1 is not queued" do
    switch_on
    application = apply
    interview = application.interview
    assert interview&.open?
    participation = application.participations.find_by!(stage: s1(@job))
    assert_nil participation.reload.screening_state
    assert_no_enqueued_jobs only: ScreenParticipationJob
  end

  test "switch off: no interview and S1 is queued as before" do
    application = apply
    assert_nil application.interview
    assert_enqueued_jobs 1, only: ScreenParticipationJob
  end

  test "no interview when AI_SCREENING_REVIEW is required, when AI is off, or for a knocked-out candidate" do
    switch_on
    required = with_env({ "AI_SCREENING_REVIEW" => "required" }) { with_ai(FakeGemini.new) { submit!(@job, cv: pdf_upload(pdf_with_text(FIXTURE_CV))).first } }
    assert_nil required.interview

    ai_off = auto { submit!(@job, email: "off@uji.example", cv: pdf_upload(pdf_with_text(FIXTURE_CV))).first }
    assert_nil ai_off.interview

    out = apply(FakeGemini.new, email: "out@uji.example", knockout: answers_for(@job, "tidak"))
    assert_nil out.interview
  end

  test "Finish queues S1 once and a second Finish does nothing" do
    switch_on
    application = apply
    interview = application.interview
    auto do
      with_ai(FakeGemini.new) do
        Interviews::Finish.call(interview, reason: "ended_by_candidate")
        assert_enqueued_jobs 1, only: ScreenParticipationJob
        Interviews::Finish.call(interview.reload, reason: "time_up")
        assert_enqueued_jobs 1, only: ScreenParticipationJob
      end
    end
    assert_equal ["finished", "ended_by_candidate"], interview.reload.then { |i| [i.status, i.finish_reason] }
    assert interview.finished_at
  end

  test "HR 'Mulai screening' never cuts off a chat that is live, but does run one that ran out of time" do
    switch_on
    application = apply
    participation = application.participations.find_by!(stage: s1(@job))
    interview = application.interview
    interview.update!(started_at: Time.current)
    auto do
      with_ai(FakeGemini.new) do
        assert_equal :interview_pending, Screening::Enqueue.call(participation, rerun: true), "a live chat is left alone"
        assert interview.reload.open?
        interview.update!(started_at: 31.minutes.ago)
        assert_equal :queued, Screening::Enqueue.call(participation, rerun: true), "past its 30 minutes the tick would close it anyway"
      end
    end
    assert_equal "staff_started", interview.reload.finish_reason
  end

  test "Enqueue with rerun queues S1 while the interview is open and closes it as staff_started" do
    switch_on
    application = apply
    participation = application.participations.find_by!(stage: s1(@job))
    auto do
      with_ai(FakeGemini.new) do
        assert_equal :interview_pending, Screening::Enqueue.blocked_reason(participation)
        assert_equal :queued, Screening::Enqueue.call(participation, rerun: true)
      end
    end
    assert_equal "staff_started", application.interview.reload.finish_reason
    assert application.interview.finished?
  end
end
