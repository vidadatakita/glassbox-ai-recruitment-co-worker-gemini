require "test_helper"

# D52 (4): an appointment becomes a Google Calendar event with the candidate and the interviewer
# as attendees and invites sent by Google. Every Google request is stubbed (WebMock); an
# unstubbed one raises, so these tests prove no real call is made.
class GoogleIntegration::CalendarTest < ActiveSupport::TestCase
  setup do
    @job = portal_job
    open_portal(@job)
    @application, = submit!(@job, name: "Rina Pratiwi", email: "Rina@Uji.Example")
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    participation = enter_stage_by_choice!(@application, s5, attendance: "pending")
    @consultant = staff_user("consultant", email: "rangga@uji.example")
    @appointment = participation.create_appointment!(starts_at: Time.zone.parse("2026-10-22 03:00 UTC"), ends_at: Time.zone.parse("2026-10-22 04:00 UTC"),
                                                     mode: "video", place_or_link: "https://meet.example/abc", contact: "Rangga 0812",
                                                     reschedule_reason: "ALASAN-PRIBADI-PELAMAR", confirmation: "pending")
    AppointmentChange.create!(appointment: @appointment, old_starts_at: nil, new_starts_at: @appointment.starts_at,
                              actor_id: @consultant.id, created_at: Time.current)
  end

  test "off while GOOGLE_CALENDAR_ID or the service account is missing: no request, nothing stored" do
    assert_equal :off, GoogleIntegration::Calendar.sync(@appointment)
    with_env("GOOGLE_CALENDAR_ID" => "jadwal@uji.example") { assert_equal :off, GoogleIntegration::Calendar.sync(@appointment) }
    assert_nil @appointment.reload.calendar_status
    assert_equal 0, GoogleIntegration::Event.count
  end

  test "creates the event with Google-sent invites, the right attendees and no private text" do
    stub_google_token!
    created = stub_request(:post, calendar_events_url).with(query: { "sendUpdates" => "all" })
                                                      .to_return(json_response({ id: "evt-1", status: "confirmed" }))
    result = with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }

    assert_equal :synced, result
    assert_requested created, times: 1
    body = nil
    assert_requested(:post, calendar_events_url, query: { "sendUpdates" => "all" }) { |req| body = JSON.parse(req.body) }
    assert_includes body["summary"], "Rina Pratiwi"
    assert_includes body["summary"], "Staf Admin Gudang"
    assert_equal %w[rangga@uji.example rina@uji.example], body["attendees"].map { |a| a["email"] }.sort
    assert_equal "2026-10-22T10:00:00+07:00", body.dig("start", "dateTime"), "WIB, not UTC"
    assert_equal "Asia/Jakarta", body.dig("start", "timeZone")
    assert_equal false, body["guestsCanSeeOtherGuests"]
    text = body.to_json
    refute_includes text, "ALASAN-PRIBADI-PELAMAR", "the candidate's free text never goes to Google"
    refute_includes text, "081234567890", "no candidate phone"
    refute_match(/\b(skor|score|nilai|AI|lolos|eliminasi)\b/i, text, "no score, outcome or AI content in the event")

    @appointment.reload
    assert_equal [ "evt-1", "synced", nil ], [ @appointment.calendar_event_id, @appointment.calendar_status, @appointment.calendar_error ]
    assert_equal "ok", GoogleIntegration::Event.latest(:calendar).outcome
  end

  test "an appointment that already has an event is updated, not duplicated" do
    @appointment.update_columns(calendar_event_id: "evt-1", calendar_status: "synced")
    stub_google_token!
    updated = stub_request(:put, "#{calendar_events_url}/evt-1").with(query: { "sendUpdates" => "all" })
                                                                .to_return(json_response({ id: "evt-1" }))
    assert_equal :synced, with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }
    assert_requested updated, times: 1
    assert_not_requested :post, calendar_events_url, query: hash_including({})
  end

  test "an event deleted by hand in Google is created again on the next sync" do
    @appointment.update_columns(calendar_event_id: "evt-gone", calendar_status: "failed")
    stub_google_token!
    stub_request(:put, "#{calendar_events_url}/evt-gone").with(query: hash_including({})).to_return(json_response({ error: { code: 404 } }, status: 404))
    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({ id: "evt-2" }))
    assert_equal :synced, with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }
    assert_equal "evt-2", @appointment.reload.calendar_event_id
  end

  test "a Google failure is stored on the appointment and in the events, never raised, and the appointment stays" do
    stub_google_token!
    stub_request(:post, calendar_events_url).with(query: hash_including({})).to_return(json_response({ error: { message: "backendError" } }, status: 503))
    assert_equal :failed, with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }
    @appointment.reload
    assert_equal "failed", @appointment.calendar_status
    assert_match(/Google::Apis::ServerError/, @appointment.calendar_error)
    assert_nil @appointment.calendar_event_id
    event = GoogleIntegration::Event.latest(:calendar)
    assert_equal [ "failed", "sync" ], [ event.outcome, event.source ]
  end

  test "a refused service account (token endpoint 400) is a visible failure too" do
    stub_google_token!(status: 400, body: { error: "unauthorized_client", error_description: "Client is unauthorized" })
    assert_equal :failed, with_calendar_env { GoogleIntegration::Calendar.sync(@appointment) }
    assert_equal "failed", @appointment.reload.calendar_status
    assert_match(/unauthorized_client|Authorization/i, @appointment.calendar_error)
  end

  test "a malformed service-account JSON is a visible failure, not a crash after the save" do
    with_env(GoogleStubs::CALENDAR_ENV.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => "{not json")) do
      assert_equal :failed, GoogleIntegration::Calendar.sync(@appointment)
    end
    assert_match(/Glassbox::GoogleKey::Invalid: service account JSON is not valid \(line 1 column \d+\)/, @appointment.reload.calendar_error)
  end

  test "cancel deletes the event with notices to attendees; an already deleted event counts as cancelled" do
    @appointment.update_columns(calendar_event_id: "evt-1", calendar_status: "synced")
    stub_google_token!
    deleted = stub_request(:delete, "#{calendar_events_url}/evt-1").with(query: { "sendUpdates" => "all" }).to_return(status: 204)
    assert_equal :cancelled, with_calendar_env { GoogleIntegration::Calendar.cancel(@appointment) }
    assert_requested deleted, times: 1
    assert_equal "cancelled", @appointment.reload.calendar_status

    @appointment.update_columns(calendar_status: "synced")
    stub_request(:delete, "#{calendar_events_url}/evt-1").with(query: hash_including({})).to_return(json_response({}, status: 410))
    assert_equal :cancelled, with_calendar_env { GoogleIntegration::Calendar.cancel(@appointment) }
  end

  test "withdrawing consent cancels the calendar invite (Pasal 40)" do
    @appointment.update_columns(calendar_event_id: "evt-1", calendar_status: "synced")
    stub_google_token!
    deleted = stub_request(:delete, "#{calendar_events_url}/evt-1").with(query: hash_including({})).to_return(status: 204)
    with_calendar_env { Portal::CandidateActions.new(@application).withdraw_consent! }
    assert_requested deleted, times: 1
    assert_equal "cancelled", @appointment.reload.calendar_status
    assert @application.reload.consent_withdrawn_at, "the withdrawal itself is committed"
  end
end
