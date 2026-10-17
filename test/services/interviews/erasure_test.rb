require "test_helper"

class Interviews::ErasureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    Portal::UpdateSetting.call(key: "ai_interview", value: "1", actor: staff_user("admin"))
    @application = with_env({ "AI_SCREENING_REVIEW" => "auto" }) do
      with_ai(FakeGemini.new) { submit!(@job, name: "Rina Pratiwi", email: "rina@uji.example", cv: pdf_upload(pdf_with_text(FIXTURE_CV))).first }
    end
    @interview = @application.interview
    now = Time.current
    @interview.update!(started_at: now)
    @interview.turns.create!(position: 1, question: "Which equipment?", asked_at: now, answer_raw: "Forklift, call 0812", answer_clean: "Forklift", answered_at: now)
    @interview.turns.create!(position: 2, question: "Anything else?", asked_at: now)
  end

  def texts = InterviewTurn.where(interview_id: @interview.id).pluck(:question, :answer_raw, :answer_clean)

  test "withdrawing consent nulls every question and answer and finishes an open interview" do
    Portal::CandidateActions.new(@application).withdraw_consent!
    assert_equal [[nil, nil, nil], [nil, nil, nil]], texts
    assert_equal "consent_withdrawn", @interview.reload.finish_reason
    erasure = InterviewErasure.find_by!(interview_id: @interview.id)
    assert_equal "consent_withdrawn", erasure.reason
    assert_nil erasure.actor_id
  end

  test "erasing twice is a no-op" do
    CandidateErasure.call(application: @application, reason: "consent_withdrawn")
    assert_no_difference "InterviewErasure.count" do
      CandidateErasure.call(application: @application, reason: "consent_withdrawn")
    end
  end

  test "retention expiry erases the interview texts too and leaves the finish reason" do
    Interviews::Finish.call(@interview, reason: "completed", queue: false)
    CandidateErasure.call(application: @application, reason: "retention_expired")
    assert_equal [[nil, nil, nil], [nil, nil, nil]], texts
    assert_equal "completed", @interview.reload.finish_reason
  end

  test "the interview row and the turn rows stay (who, when, how it ended)" do
    CandidateErasure.call(application: @application, reason: "consent_withdrawn")
    assert_equal 2, InterviewTurn.where(interview_id: @interview.id).count
    assert Interview.exists?(@interview.id)
  end

  test "an erasure record cannot be changed" do
    CandidateErasure.call(application: @application, reason: "consent_withdrawn")
    assert_raises(ActiveRecord::ReadOnlyRecord) { InterviewErasure.last.update!(reason: "no_consent") }
  end
end
