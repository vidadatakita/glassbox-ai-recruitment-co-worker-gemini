require "test_helper"

# D52 screens: the appointment's calendar state ("The calendar invitation could not be sent" + retry)
# and the "Google integrations" section of Settings, which must never print a secret.
class GoogleScreensTest < ActionDispatch::IntegrationTest
  SECRETS = { "GOOGLE_OAUTH_CLIENT_ID" => "uji-id.apps.googleusercontent.com",
              "GOOGLE_OAUTH_CLIENT_SECRET" => "RAHASIA-CLIENT-SECRET-123",
              "GOOGLE_MAIL_USERNAME" => "hr@uji.example", "GOOGLE_MAIL_APP_PASSWORD" => "RAHASIA-APP-PASSWORD",
              "GOOGLE_STORAGE_BUCKET" => "glassbox-uji-bucket" }.freeze

  setup do
    @job = portal_job
    open_portal(@job)
    @application, = submit!(@job)
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    @participation = enter_stage_by_choice!(@application, s5, attendance: "pending")
    @consultant = staff_user("consultant")
  end

  def schedule_params
    { appointment: { starts_at: "2026-10-22T10:00", ends_at: "2026-10-22T11:00", mode: "onsite",
                     place_or_link: "Kantor Bekasi", contact: "Rangga 0812" } }
  end

  test "a failed invite never blocks the schedule; the failure shows on the appointment with a retry outside the form" do
    sign_in_as(@consultant)
    stub_google_token!
    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({}, status: 500))

    assert_difference -> { Appointment.count } => 1 do
      with_calendar_env { post staff_participation_appointments_path(@participation), params: schedule_params }
    end
    assert_redirected_to staff_application_path(@application)
    assert_equal "Appointment saved.", flash[:notice]
    assert_match "The calendar invitation could not be sent", flash[:alert]
    appointment = Appointment.last
    assert_equal "failed", appointment.calendar_status

    follow_redirect!
    page = Nokogiri::HTML(response.body)
    assert_match "The calendar invitation could not be sent", page.text
    retry_form = page.at_css("form[action='#{calendar_staff_appointment_path(appointment)}']")
    assert retry_form, "the retry button is shown"
    assert_empty page.css("form form"), "hard rule: no form inside a form"
    assert_nil retry_form.at_css("[disabled]"), "hard rule: a submit button is never disabled"

    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({ id: "evt-9" }))
    with_calendar_env { post calendar_staff_appointment_path(appointment) }
    assert_equal "Calendar invitation sent.", flash[:notice]
    assert_equal [ "synced", "evt-9" ], [ appointment.reload.calendar_status, appointment.calendar_event_id ]
  end

  test "without calendar credentials scheduling is exactly as before: no call, no calendar line" do
    sign_in_as(@consultant)
    post staff_participation_appointments_path(@participation), params: schedule_params
    assert_equal "Appointment saved.", flash[:notice]
    assert_nil flash[:alert]
    assert_nil Appointment.last.calendar_status
    follow_redirect!
    assert_no_match "Calendar invitation", response.body
  end

  # Three roles (17 Oct 2026): appointments belong to the hr_admin (old consultant and HR PIC); the
  # hr_manager (old owner and reviewer) is refused.
  test "only an hr_admin can resend an invite; an hr_manager is refused" do
    appointment = @participation.create_appointment!(starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, mode: "onsite",
                                                     place_or_link: "Kantor", contact: "Rangga", confirmation: "pending")
    appointment.update_columns(calendar_status: "failed")
    sign_in_as(staff_user("owner"))
    with_calendar_env { post calendar_staff_appointment_path(appointment) }
    assert_equal "You do not have access to this action.", flash[:alert]
    assert_equal "failed", appointment.reload.calendar_status
  end

  test "Google integrations shows Not configured for everything on a fresh install" do
    sign_in_as(staff_user("admin"))
    get staff_settings_path
    section = Nokogiri::HTML(response.body).at_css("#integrasi-google")
    assert section, "the section is on Settings"
    assert_equal %w[off off off off], section.css("[data-google-state]").map { |b| b["data-google-state"] }
    assert_equal 4, section.text.scan("Not configured").size, "one badge per integration (the detail rows say lowercase not configured)"
  end

  test "Google integrations shows Active and Last failed, and never prints a secret" do
    GoogleIntegration::Event.record!(:login, source: :check)
    GoogleIntegration::Event.record!(:calendar, source: :sync, error: RuntimeError.new("Google::Apis::ServerError: backendError"))
    sign_in_as(staff_user("admin"))
    with_env(SECRETS.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => fake_service_account_json, "GOOGLE_CALENDAR_ID" => "jadwal@uji.example")) do
      get staff_settings_path
    end
    section = Nokogiri::HTML(response.body).at_css("#integrasi-google")
    states = section.css("[data-google-state]").map { |b| b["data-google-state"] }
    assert_equal %w[active active off failed], states, "login, mail, storage (credentials but still local), calendar"
    assert_match(/Last failed: \w+, \d+ \w+ \d{4}, \d{2}:\d{2} WIB/, section.text)
    assert_match "backendError", section.text
    assert_match "configured (ENV GOOGLE_OAUTH_CLIENT_SECRET)", section.text

    body = response.body
    private_key = JSON.parse(fake_service_account_json)["private_key"]
    [ "RAHASIA-CLIENT-SECRET-123", "RAHASIA-APP-PASSWORD", private_key.lines[1].strip, "BEGIN RSA PRIVATE KEY", "BEGIN PRIVATE KEY" ].each do |secret|
      refute_includes body, secret, "a secret reached the page"
    end
  end

  test "Settings stays admin-only" do
    sign_in_as(staff_user("hr_pic"))
    get staff_settings_path
    assert_redirected_to staff_jobs_path
  end
end
