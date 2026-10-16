require "test_helper"

# AI Builder Cup step 04: every application is acknowledged by email; the same person applying more
# than once (same email, phone or CV file, within the company) is flagged for staff, never merged.
class DuplicateAndAckTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  test "an application on a job without a technical test gets the acknowledgement with its status link" do
    job = portal_job
    open_portal(job)
    lamaran = application_params(job).except(:knockout).merge(consent_token: shown_consent_token)
    assert_emails 1 do
      post lamar_path(job.public_code), params: { knockout: answers_for(job), lamaran: }
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal "Application received: #{job.title}", mail.subject
    assert_match %r{/status/}, mail.body.to_s
    assert MailDelivery.find_by(kind: "application_ack").sent?
  end

  test "the same email, phone (any notation) or CV file is flagged on both applications; others are not" do
    job = portal_job
    open_portal(job)
    first, = submit!(job, email: "rina@uji.example", phone: "081234567890")
    second, = submit!(job, name: "Rina P.", email: "RINA@uji.example ", phone: "+62 812-3456-7890")
    third, = submit!(job, name: "Budi", email: "budi@uji.example", phone: "081300000000", cv: pdf_upload("%PDF-1.4 lain\n%%EOF\n"))

    flags = Portal::DuplicateCheck.flags(job.client_company_id)
    assert_equal ["same email", "same phone number", "same CV file"], flags[first.id]
    assert_equal flags[first.id], flags[second.id]
    assert_empty flags[third.id]
    assert_equal [second.id], Portal::DuplicateCheck.for(first).map { |m| m.application.id }

    sign_in_as staff_user("hr_pic")
    get staff_application_path(first)
    assert_includes response.body, "Possible duplicate application"
    get staff_job_path(job)
    assert_equal 2, Nokogiri::HTML(response.body).css("span.portal-state").count { |s| s.text.strip == "Possible duplicate" }
  end
end
