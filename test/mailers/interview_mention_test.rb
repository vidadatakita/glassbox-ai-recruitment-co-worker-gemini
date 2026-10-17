require "test_helper"

class InterviewMentionTest < ActionMailer::TestCase
  setup do
    @job = portal_job
    open_portal(@job)
    @application, @token = submit!(@job)
  end

  def body(mail) = mail.text_part&.body&.to_s || mail.body.to_s

  test "with an open interview the acknowledgement carries the interview link and the time" do
    Interview.create!(job_application: @application)
    text = body(CandidateMailer.application_ack(@application, @token))
    assert_includes text, "interview"
    assert_includes text, "/status/#{@token}/interview"
    assert_includes text, "30 minutes"
  end

  test "with an open interview the technical-test email carries the interview link too" do
    Interview.create!(job_application: @application)
    text = body(CandidateMailer.application_received(@application, @token, start_by: 2.days.from_now, minutes: 120))
    assert_includes text, "/status/#{@token}/interview"
  end

  test "without an interview the acknowledgement does not mention one" do
    text = body(CandidateMailer.application_ack(@application, @token))
    refute_match(/interview/i, text)
  end

  test "a finished interview is not mentioned" do
    interview = Interview.create!(job_application: @application)
    Interviews::Finish.call(interview, reason: "completed", queue: false)
    refute_match(/interview/i, body(CandidateMailer.application_ack(@application, @token)))
  end
end
