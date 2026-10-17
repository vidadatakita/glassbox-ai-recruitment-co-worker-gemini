require "test_helper"

# Blueprint §4.1 steps 1-2, §4.3, D50: when the AI must NOT be called.
class Screening::GatesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup { @job = screening_job }

  # D51 (feature 09) changed this test. Before: with no key nothing was queued and the state stayed
  # "not asked". Now the CV is prepared LOCALLY (evidence sections, redaction, residual check) and
  # waits in "Menunggu pemeriksaan"; still nothing is sent and nothing is scored, and the release
  # itself is refused until the key is set ("without a key, items wait", coordinator, D51 build).
  test "no API key: nothing is sent, no score; the CV waits in Awaiting review and cannot be released" do
    fake = FakeGemini.new
    Screening::AiClient.http_override = fake
    Screening::Config.stub(:api_key, nil) do
      participation = apply_with_cv!(@job)
      perform_enqueued_jobs
      assert_equal "awaiting_release", participation.reload.screening_state
      assert_empty participation.score_entries
      assert_equal [participation], ScreeningBoard.new(@job).awaiting_release
      release = AiRelease.latest_for(participation)
      error = assert_raises(AiReleases::Refused) do
        AiReleases::Release.call(release:, user: staff_user("reviewer"), confirmed: "1", seen_sha256: release.payload_sha256)
      end
      assert_includes error.message, ScreeningBoard::OFF_MESSAGE
      assert_nil release.reload.action
    end
    assert_empty fake.requests
  ensure
    Screening::AiClient.http_override = nil
  end

  test "the key is read from credentials or ENV; blank means off" do
    Rails.application.credentials.stub(:dig, nil) do
      with_env("AI_API_KEY" => "  ") { refute Screening::Config.enabled? }
      with_env("AI_API_KEY" => "sk-from-env") { assert_equal "sk-from-env", Screening::Config.api_key }
    end
    Rails.application.credentials.stub(:dig, "sk-from-credentials") do
      with_env("AI_API_KEY" => "sk-from-env") { assert_equal "sk-from-credentials", Screening::Config.api_key }
    end
  end

  test "the model is one setting with the D50 default" do
    with_env("AI_MODEL" => nil, "AI_MODEL_HIGH" => nil) { assert_equal "gemini-3.8-flash", Screening::Config.model }
    with_env("AI_MODEL" => "gemini-3.5-flash-lite") { assert_equal "gemini-3.5-flash-lite", Screening::Config.model }
  end

  # D51: the key is checked again just before the call. Removed after the release: no call,
  # "Screening gagal" with the reason; once the key is back, "Mulai screening" sends the SAME
  # released text (no second review: it is byte for byte what the reviewer approved).
  test "a key removed after the release: no call, failed with the reason, and the same text is sent once the key is back" do
    fake = FakeGemini.new
    with_ai(fake) do
      @participation = apply_with_cv!(@job)
      perform_enqueued_jobs
      release_held!
    end
    assert_equal "queued", @participation.reload.screening_state
    Screening::AiClient.http_override = fake
    Screening::Config.stub(:api_key, nil) { perform_enqueued_jobs }
    assert_empty fake.requests
    assert_equal "screening_failed", @participation.reload.screening_state
    assert_equal "config", @participation.screening_failure
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      Screening::Start.call(@job)
      perform_enqueued_jobs
    end
    assert_equal "done", @participation.reload.screening_state
    assert_equal AiRelease.latest_for(@participation).payload_text, JSON.parse(fake.bodies.first).dig("contents", 0, "parts", 0, "text")
  ensure
    Screening::AiClient.http_override = nil
  end

  test "knockout 'tidak' (rule 16): the AI is never called" do
    fake = FakeGemini.new
    with_ai(fake) do
      application, = submit!(@job, knockout: answers_for(@job, "tidak"), cv: pdf_upload(pdf_with_text(FIXTURE_CV)))
      perform_enqueued_jobs
      assert_equal :knocked_out, Screening::Enqueue.blocked_reason(application.participations.first)
    end
    assert_empty fake.requests
  end

  test "consent withdrawn before the job runs (D15 gate): the AI is never called" do
    fake = FakeGemini.new
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      participation.job_application.update!(consent_withdrawn_at: Time.current)
      perform_enqueued_jobs
      assert_equal :withdrawn, Screening::Enqueue.blocked_reason(participation)
    end
    assert_empty fake.requests
  end

  test "an application without recorded consent never reaches the AI" do
    application = JobApplication.create!(job: @job)  # no candidate, no consent: the only shape the database allows
    participation = Participation.create!(job_application: application, stage: s1(@job))
    with_ai(FakeGemini.new) { assert_equal :no_candidate, Screening::Enqueue.call(participation) }
    # The database refuses a candidate's application without consent (feature 02), so the
    # Enqueue :no_consent gate is the second line, proven directly here.
    Screening::Config.stub(:api_key, FAKE_KEY) do
      blocked = Screening::Enqueue.new(participation)
      application.define_singleton_method(:candidate_id) { 1 }
      assert_equal :no_consent, blocked.blocked_reason
    end
  end

  test "a PDF with no text layer: CV tidak terbaca, no call, no score; pasted text puts it back in the queue" do
    fake = FakeGemini.new
    with_ai(fake) do
      @participation = apply_with_cv!(@job, pdf: pdf_without_text)
      perform_enqueued_jobs
    end
    @participation.reload
    assert_equal "cv_unreadable", @participation.screening_state
    assert_empty fake.requests
    assert_empty @participation.score_entries

    consultant = @job.consultant
    assert_raises(Screening::PasteCvText::Refused) do
      Screening::PasteCvText.call(participation: @participation, user: consultant, text: "terlalu pendek")
    end
    assert_raises(Screening::PasteCvText::Refused) do
      Screening::PasteCvText.call(participation: @participation, user: staff_user("hr_pic"), text: FIXTURE_CV)
    end
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      Screening::PasteCvText.call(participation: @participation, user: consultant, text: FIXTURE_CV)
      screen_and_release! # D51 B
    end
    assert_equal "done", @participation.reload.screening_state
    assert_equal "pasted", @participation.job_application.cv_text_source
    assert_equal consultant.id, @participation.job_application.cv_text_by_id
    PROTECTED.each { |value| refute_includes fake.bodies.last, value }
  end

  test "a second callback or a double click queues nothing twice" do
    with_ai(FakeGemini.new) do
      participation = apply_with_cv!(@job)
      assert_equal :already, Screening::Enqueue.call(participation)
      assert_equal 1, enqueued_jobs.size
    end
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
