require "test_helper"

# Test engine, feature 10 (D52 (4)): how does the Google Calendar invite break?
# Every Google request is a WebMock stub; an unstubbed one raises.
#
# Claim -> mutant -> test that goes red:
# - "the event text holds stage, name, job title, time, place, bring, contact; never a score, a
#   decision, AI output or candidate free text" -> one extra field in build_event -> G-C1 (exact
#   allowlist, with a decision and a reschedule reason present in the fixture)
# - "a Google failure never undoes the save" -> G-C2 (update path; the builder covers create)
# - "the message never holds a credential" (Event, Status) -> G-C3 (FINDING F-10-01)
# - "withdrawal cancels the invite (Pasal 40)" -> G-C4: a failed cancel must be retryable
#   (FINDING F-10-02)
class GoogleEngineCalendarTest < ActionDispatch::IntegrationTest
  KEY_MARKER = "ENGINE-KUNCI-PRIVAT-RAHASIA".freeze

  setup do
    @job = portal_job
    open_portal(@job)
    @application, = submit!(@job, name: "Rina Pratiwi", email: "rina@uji.example")
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    # D63 strict entry: an S5 participation exists only through a Lanjut on the previous choice stage.
    @participation = enter_stage_by_choice!(@application, s5, attendance: "pending")
    @consultant = staff_user("consultant", email: "rangga@uji.example")
    @appointment = @participation.create_appointment!(starts_at: Time.zone.parse("2026-10-22 03:00 UTC"), ends_at: Time.zone.parse("2026-10-22 04:00 UTC"),
                                                      mode: "onsite", place_or_link: "Kantor Bekasi", bring: "KTP", contact: "Rangga 0812",
                                                      reschedule_reason: "ALASAN-PRIBADI-PELAMAR", confirmation: "pending")
    AppointmentChange.create!(appointment: @appointment, old_starts_at: nil, new_starts_at: @appointment.starts_at,
                              actor_id: @consultant.id, created_at: Time.current)
  end

  # G-C1. Exact allowlist: any added field or line is red, whatever its wording.
  test "the event body is exactly the allowed fields and lines, with a decision and a reschedule reason on file" do
    Decision.create!(participation: @participation, outcome: "eliminate", basis: "manual", reason_code: "other",
                     note: "CATATAN-KEPUTUSAN-RAHASIA", decided_by_id: @consultant.id, decided_at: Time.current)
    stub_google_token!
    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({ id: "evt-1" }))
    assert_equal :synced, with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }

    body = nil
    assert_requested(:post, calendar_events_url, query: hash_including({})) { |req| body = JSON.parse(req.body) }
    assert_equal %w[attendees description end guestsCanSeeOtherGuests location reminders start summary], body.keys.sort
    stage = CandidateStatus::STAGE_LABELS.fetch("S5")
    assert_equal "#{stage}: Rina Pratiwi · #{@job.title}", body["summary"]
    assert_equal [ "#{stage} appointment for the position #{@job.title}.", "Mode: #{Appointment::MODES.fetch('onsite')}.",
                   "Place: Kantor Bekasi", "What to bring: KTP", "Contact: Rangga 0812",
                   "Confirm your attendance through the application status link in the GlassBox email." ], body["description"].split("\n")
    assert_equal "Kantor Bekasi", body["location"]
    text = body.to_json
    refute_includes text, "CATATAN-KEPUTUSAN-RAHASIA"
    refute_includes text, "ALASAN-PRIBADI-PELAMAR"
    refute_includes text, "eliminate"
  end

  # G-C2. The update path: a Google failure keeps the new time and its change log row.
  test "a rescheduled time is saved and logged even when Google answers 503" do
    sign_in_as(@consultant)
    stub_google_token!
    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({}, status: 503))
    assert_difference -> { AppointmentChange.count } => 1 do
      with_calendar_env do
        patch staff_appointment_path(@appointment), params: { appointment: { starts_at: "2026-10-23T09:00", ends_at: "2026-10-23T10:00" } }
      end
    end
    assert_equal "Appointment updated.", flash[:notice]
    assert_match "The calendar invitation could not be sent", flash[:alert]
    @appointment.reload
    assert_equal Time.zone.parse("2026-10-23T09:00"), @appointment.starts_at
    assert_equal [ "failed", "pending" ], [ @appointment.calendar_status, @appointment.confirmation ]
  end

  # G-C2b. Pressing the retry twice after it worked updates the same event; no second invite.
  test "a second retry after success updates the event instead of creating a duplicate" do
    sign_in_as(@consultant)
    stub_google_token!
    created = stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({ id: "evt-7" }))
    updated = stub_request(:put, "#{calendar_events_url}/evt-7").with(query: hash_including({})).to_return(json_response({ id: "evt-7" }))
    with_calendar_env do
      post calendar_staff_appointment_path(@appointment)
      post calendar_staff_appointment_path(@appointment)
    end
    assert_requested created, times: 1
    assert_requested updated, times: 1
  end

  # G-C3 (FINDING F-10-01). The most common paste mistake in a service-account key is real line
  # breaks inside "private_key". JSON::ParserError then quotes the input after the error point,
  # i.e. the private key itself, and that message is stored and shown.
  test "a malformed service-account key never lands in the appointment, the event table or Settings" do
    broken = %({"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\n#{KEY_MARKER}\n-----END PRIVATE KEY-----\n"})
    env = GoogleStubs::CALENDAR_ENV.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => broken)
    assert_equal :failed, with_env(env) { GoogleIntegration::Calendar.sync(@appointment) }, "control: the failure is visible"

    sign_in_as(staff_user("admin"))
    with_env(env) { get staff_settings_path }
    assert_response :success
    assert_match "Last failed", response.body, "control: the failure is on the page"

    # Collected first, so one red names every place the key reached.
    leaks = { "appointments.calendar_error" => @appointment.reload.calendar_error.to_s,
              "google_integration_events.message (append-only)" => GoogleIntegration::Event.latest(:calendar).message.to_s,
              "Settings page" => response.body }.select { |_, text| text.include?(KEY_MARKER) }.keys
    assert_empty leaks, "the private key reached: #{leaks.join(', ')}"
  end

  # G-C3b. Same input through the check task (it prints to the operator's terminal and stores).
  test "the check task does not store or print the key of a malformed service account" do
    broken = %({"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\n#{KEY_MARKER}\n-----END PRIVATE KEY-----\n"})
    results = with_env(GoogleStubs::CALENDAR_ENV.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => broken)) { GoogleIntegration::Check.run }
    calendar = results.find { |r| r.integration == :calendar }
    assert_equal :failed, calendar.status, "control"
    refute_includes calendar.message, KEY_MARKER
    refute_includes GoogleIntegration::Event.latest(:calendar).message.to_s, KEY_MARKER
  end

  # G-C4 (FINDING F-10-02). A withdrawal whose Google delete fails leaves the event (candidate's
  # name, job, time) in the company calendar and on the candidate's. The only button on the screen
  # is "Resend invitation", which refuses after a withdrawal, so the cancel can never be retried.
  test "after a withdrawal whose Google cancel failed, the consultant can retry the CANCEL" do
    @appointment.update_columns(calendar_event_id: "evt-1", calendar_status: "synced")
    stub_google_token!
    deleted = stub_request(:delete, "#{calendar_events_url}/evt-1").with(query: hash_including({})).to_return(json_response({}, status: 500))
    with_calendar_env { Portal::CandidateActions.new(@application).withdraw_consent! }
    assert_equal "failed", @appointment.reload.calendar_status, "control: the first cancel failed"
    assert_requested deleted, times: 1

    stub_request(:delete, "#{calendar_events_url}/evt-1").with(query: hash_including({})).to_return(status: 204)
    sign_in_as(@consultant)
    with_calendar_env { post calendar_staff_appointment_path(@appointment) }
    assert_requested :delete, "#{calendar_events_url}/evt-1", query: hash_including({}), times: 2
    assert_equal "cancelled", @appointment.reload.calendar_status
  end
end
