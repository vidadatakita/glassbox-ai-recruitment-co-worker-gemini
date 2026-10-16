require "test_helper"
require Rails.root.join("db/seeds/demo_technical_test").to_s

# D52: the technical-test demo seed covers every slice-3-5 state and is idempotent.
class DemoTechnicalTestSeedTest < ActiveSupport::TestCase
  test "every test state on two demo jobs, notices recorded, and a second run writes nothing" do
    set_retention
    publish_consent
    args = { company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer") }
    open, closed = DemoTechnicalTest.run(**args)
    states = ->(job) { job.job_applications.joins(:candidate).order("candidates.name").map { |a| TechnicalTests::Status.new(a).state } }
    assert_equal %i[not_started running sent sent sent expired expired], states.(open)
    s2_reasons = ->(job) { job.job_applications.joins(:candidate).order("candidates.name").map { |a| TechnicalTests.participation_for(a).current_decision&.reason_code } }
    assert_equal [nil, nil, nil, "at_or_above_threshold", "below_threshold", "no_show", "no_show"], s2_reasons.(open)
    assert_equal %w[at_or_above_threshold gate_eliminated no_show], s2_reasons.(closed)
    assert_equal "closed", closed.stages.find_by!(code: "S2").status
    assert_equal %w[application_received gate_outcome test_receipt test_reminder], MailDelivery.distinct.order(:kind).pluck(:kind)
    assert_equal 3, MailDelivery.where(kind: "gate_outcome").count
    assert_match(/@contoh\.example\z/, Candidate.pluck(:email).uniq.join(" ")) # invented addresses only

    counts = -> { [JobApplication.count, TestAttempt.count, TestReview.count, Decision.count, MailDelivery.count] }
    before = counts.()
    DemoTechnicalTest.run(**args)
    assert_equal before, counts.(), "the second run writes nothing"
  end
end
