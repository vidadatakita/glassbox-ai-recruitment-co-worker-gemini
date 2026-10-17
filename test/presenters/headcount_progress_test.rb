require "test_helper"

# Places filled (Vida 17 Oct 2026): an applicant fills a place at "Salary agreed"; a withdrawal or a
# declined newest offer frees it; accepted is counted among the filled; open never goes below 0.
class HeadcountProgressTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    @job.update_columns(headcount: 2)
    @owner = staff_user("owner")
  end

  def agreed!(application)
    SalaryAgreement.create!(job_application: application, agreed_amount: 8_000_000, outside_band: false, decided_by: @owner, created_at: Time.current)
  end

  test "counts salary agreed, frees a place on withdrawal or a declined offer, counts acceptances" do
    a, = applicant!(@job, name: "Satu")
    b, = applicant!(@job, name: "Dua")
    c, = applicant!(@job, name: "Tiga")
    hc = -> { HeadcountProgress.new(@job) }
    assert_equal [0, 2, 2], [hc.call.filled, hc.call.needed, hc.call.open]

    [a, b, c].each { |app| agreed!(app) }
    assert_equal 3, hc.call.filled
    assert hc.call.over?
    assert_equal 0, hc.call.open, "open never below zero"

    c.update_columns(consent_withdrawn_at: Time.current)
    assert_equal 2, hc.call.filled, "a withdrawal frees the place"
    assert hc.call.complete?

    # The newest offer's response, stubbed: an offer needs an uploaded PDF and dates this test does not need.
    responses = { b.id => "declined", a.id => "accepted" }
    latest = ->(application) { responses[application.id] && OfferDocument.new(response: responses[application.id]) }
    OfferDocument.stub(:latest_for, latest) do
      assert_equal 1, hc.call.filled, "a declined newest offer frees the place"
      assert_equal [1, 1, 1], [hc.call.filled, hc.call.accepted, hc.call.open]
    end
  end
end

# The partial renders the count and what is left, with no form and no disabled control.
class PortalHeadcountPartialTest < ActionView::TestCase
  include TechnicalTestFactory

  test "shows filled of needed and the places still open" do
    job = technical_test_job
    job.update_columns(headcount: 3)
    html = render(partial: "staff/jobs/portal_headcount", locals: { job: })
    assert_includes html, "0 of 3"
    assert_includes html, "3 places open"
    assert_includes html, "Salary agreed"
    refute_match(/<form|disabled/, html)
  end
end
