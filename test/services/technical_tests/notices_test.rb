require "test_helper"

# D60 slice 4 (plan §e): the technical-test emails, each at most once, through the house
# MailDelivery pattern (outcome recorded, failure in Antrean Kerja), never with a score.
class TechnicalTests::NoticesTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    ActionMailer::Base.deliveries.clear
    @t0 = Time.zone.parse("2026-10-05 09:00:00")
    @job = travel_to(@t0) { technical_test_job }
    @application, @token = travel_to(@t0) { applicant!(@job) }
  end

  def kinds = MailDelivery.where(job_application: @application).order(:id).pluck(:kind)

  test "submit notice: status link, test link and the start deadline in WIB, once" do
    delivery = travel_to(@t0) { TechnicalTests::Notices.application_received(@application, @token) }
    assert delivery.sent?
    body = ActionMailer::Base.deliveries.last.body.to_s
    assert_includes body, "/status/#{@token}"
    assert_includes body, "/status/#{@token}/technical-test"
    assert_includes body, "Wednesday, 7 October 2026, 09:00 WIB", "start_by = submit + 48 h, in WIB"
    assert_includes body, "35 minutes"
    assert_nil travel_to(@t0) { TechnicalTests::Notices.application_received(@application, @token) }
    assert_equal %w[application_received], kinds
  end

  test "reminder: not before 24 h, sent at 24 h, once, and never after a start" do
    assert_nil travel_to(@t0 + 24.hours - 1.second) { TechnicalTests::Notices.reminder(@application) }
    assert travel_to(@t0 + 24.hours) { TechnicalTests::Notices.reminder(@application) }.sent?
    assert_nil travel_to(@t0 + 30.hours) { TechnicalTests::Notices.reminder(@application) }
    assert_equal %w[test_reminder], kinds
    body = ActionMailer::Base.deliveries.last.body.to_s
    assert_includes body, "/new-link", "no token in a later email: it points to the new-link page"
    assert_no_match %r{/status/}, body

    other, = travel_to(@t0) { applicant!(@job) }
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: other) }
    assert_nil travel_to(@t0 + 25.hours) { TechnicalTests::Notices.reminder(other) }
  end

  test "the tick sends due reminders once and expires dead tests" do
    result = travel_to(@t0 + 24.hours) { TechnicalTests::Tick.call }
    assert_equal 1, result[:reminded]
    assert_equal 0, travel_to(@t0 + 25.hours) { TechnicalTests::Tick.call }[:reminded]
    result = travel_to(@t0 + 49.hours) { TechnicalTests::Tick.call }
    assert_equal 1, result[:expired]
    assert_equal "no_show", s2_of(@application).current_decision.reason_code
  end

  test "receipt: once, with the arrival time" do
    attempt = answered!(@application, at: @t0 + 2.hours)
    assert TechnicalTests::Notices.receipt(@application).sent?
    assert_nil TechnicalTests::Notices.receipt(@application)
    assert_includes ActionMailer::Base.deliveries.last.body.to_s, I18n.l(attempt.answered_at.in_time_zone, format: :long_wib)
  end

  test "the database holds one notice of each test kind per application" do
    MailDelivery.create!(job_application: @application, kind: "test_receipt", status: "failed", error_class: "SocketError")
    refused = assert_raises(ActiveRecord::RecordNotUnique) do
      MailDelivery.create!(job_application: @application, kind: "test_receipt", status: "sent")
    end
    assert_match "mail_deliveries_one_test_notice", refused.message
    assert MailDelivery.create!(job_application: @application, kind: "status_link", status: "sent")
    assert MailDelivery.create!(job_application: @application, kind: "status_link", status: "sent"), "control: re-issue links are not limited"
  end

  test "gate outcome: one email per applicant when the gate closes, with a reason category and no score" do
    passed = @application
    missed, = travel_to(@t0) { applicant!(@job) }
    travel_to(@t0 + 1.hour) do
      [passed, missed].each do |application|
        s1 = s1_of(application)
        s1.update!(attendance: "attended")
        add_score(s1, 80)
        decide!(s1, outcome: "pass")
      end
    end
    attempt = answered!(passed, at: @t0 + 2.hours)
    travel_to(@t0 + 3.hours) do
      TechnicalTests::ScoreAnswer.call(attempt:, reviewer: reviewer, ratings: ratings_for(attempt, [5, 4]), note: "Baik.")
    end
    travel_to(@t0 + 49.hours) do
      TechnicalTests::Expire.call(missed)
      Gates::Close.call(stage: s1_of(passed).stage)
    end
    outcomes = ActionMailer::Base.deliveries.select { |m| m.subject.start_with?("CV screening and technical test result") }
    assert_equal 2, outcomes.size
    passed_mail = outcomes.find { |m| m.to == [passed.candidate.email] }.body.to_s
    missed_mail = outcomes.find { |m| m.to == [missed.candidate.email] }.body.to_s
    assert_includes passed_mail, "You passed this stage"
    assert_includes missed_mail, TechnicalTests::GateOutcome::TEST_NO_SHOW
    [passed_mail, missed_mail].each { |body| assert_no_match(/\b(80|90|95)\b|skor|batas lolos|\bscore\b|pass score/i, body) }
    assert_equal 0, travel_to(@t0 + 50.hours) { TechnicalTests::Tick.call }[:outcomes], "the tick does not send again"
  end
end
