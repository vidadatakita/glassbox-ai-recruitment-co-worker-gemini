require "test_helper"

# F-10-01 and the 18:4x security review: no part of a service-account key may reach any place the
# Google integration stores or shows an error. The check is strict on purpose: NO substring of 8 or more
# characters of the input may appear in the message, the full message, the cause chain, the Rails
# log, google_integration_events, appointments.calendar_error, Settings or the check output.
class GoogleIntegration::KeyLeakTest < ActionDispatch::IntegrationTest
  KEY_BODY = "MIIEvQZXqYk3Lw9TfRbN2cVhG7uJpEo4sDaWlK8mHzQiCy5xBn1tFgUeRjOd6PvS".freeze
  # Real line breaks inside "private_key": the commonest paste mistake, and invalid JSON.
  BROKEN = %({"private_key":"-----BEGIN PRIVATE KEY-----\n#{KEY_BODY}\n-----END PRIVATE KEY-----\n"}).freeze

  # Every 8-character window of the input that appears in the text.
  def leaked(text, input = BROKEN)
    text = text.to_s
    (0..input.length - 8).map { |i| input[i, 8] }.uniq.select { |w| text.include?(w) }
  end

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def cause_chain(error)
    chain = []
    while error
      chain << "#{error.class}: #{error.message}"
      error = error.cause
    end
    chain.join("\n")
  end

  test "the parse error carries no part of the input in its message, full message or cause" do
    error = assert_raises(Glassbox::GoogleKey::Invalid) { Glassbox::GoogleKey.parse(BROKEN) }
    assert_empty leaked(error.message)
    assert_empty leaked(error.full_message(highlight: false))
    assert_nil error.cause
    assert_empty leaked(cause_chain(error))
    assert_match(/\Aservice account JSON is not valid \(line \d+ column \d+\)/, error.message, "control: the error still says what is wrong and where")
  end

  test "a malformed key reaches no table, log line, page or check output" do
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    s5 = job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    participation = enter_stage_by_choice!(application, s5, attendance: "pending")
    appointment = participation.create_appointment!(starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, mode: "onsite",
                                                    place_or_link: "Kantor", contact: "Rangga", confirmation: "pending")
    env = GoogleStubs::CALENDAR_ENV.merge("GOOGLE_SERVICE_ACCOUNT_JSON" => BROKEN, "GOOGLE_STORAGE_BUCKET" => "glassbox-uji-bucket")

    results = nil
    log = capture_log do
      with_env(env) do
        assert_equal :failed, GoogleIntegration::Calendar.sync(appointment), "control: the failure is visible"
        results = GoogleIntegration::Check.run
      end
    end
    assert_equal %i[failed failed], results.select { |r| %i[storage calendar].include?(r.integration) }.map(&:status), "control"

    sign_in_as(staff_user("admin"))
    page_log = capture_log { with_env(env) { get staff_settings_path } }
    assert_match "Last failed", response.body, "control: the failure is on the page"

    places = {
      "appointments.calendar_error" => appointment.reload.calendar_error,
      "google_integration_events" => GoogleIntegration::Event.pluck(:error_class, :message).flatten.join("\n"),
      "check output" => results.map(&:message).join("\n"),
      "Rails log" => log + page_log,
      "Settings page" => response.body
    }
    leaks = places.transform_values { |text| leaked(text) }.reject { |_, found| found.empty? }
    assert_empty leaks, "key text reached: #{leaks.keys.join(', ')}"
  end

  # Defence in depth: an error from Google or a library that QUOTES a PEM key is redacted before
  # it is stored, whatever the parse step did.
  test "an error message quoting a private key is redacted before it is stored" do
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    s5 = job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    participation = enter_stage_by_choice!(application, s5, attendance: "pending")
    appointment = participation.create_appointment!(starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, mode: "onsite",
                                                    place_or_link: "Kantor", contact: "Rangga", confirmation: "pending")
    pem = "-----BEGIN PRIVATE KEY-----\n#{KEY_BODY}\n-----END PRIVATE KEY-----"
    require "google/apis/calendar_v3"
    quoting = Google::Apis::ClientError.new("bad key #{pem}", status_code: 400)
    with_calendar_env do
      GoogleIntegration::Client.stub(:calendar, -> { raise quoting }) do
        assert_equal :failed, GoogleIntegration::Calendar.sync(appointment)
      end
    end
    assert_empty leaked(appointment.reload.calendar_error, pem)
    assert_empty leaked(GoogleIntegration::Event.latest(:calendar).message, pem)
    assert_match "[key redacted]", appointment.calendar_error, "control: the rest of the message is kept"
  end

  test "google_integration_events redacts a quoted key on its own, whoever the caller is" do
    pem = "-----BEGIN PRIVATE KEY-----\n#{KEY_BODY}\n-----END PRIVATE KEY-----"
    event = GoogleIntegration::Event.record!(:storage, source: :check, message: "failed #{pem} again")
    assert_empty leaked(event.message, pem)
    assert_equal "failed [key redacted] again", event.message
  end
end
