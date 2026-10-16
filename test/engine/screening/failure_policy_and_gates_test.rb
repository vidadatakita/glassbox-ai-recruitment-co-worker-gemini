require "test_helper"
require_relative "screening_engine_support"

# Blueprint §4.3 and §5.2: timeout / API error -> 3 retries with increasing wait, malformed -> 1
# retry, then "Screening gagal"; never a default score. On EVERY failure path: no ScoreEntry, no
# ScreeningResult, no Decision. §4.1 steps 1-2 and D50: gates closed -> no HTTP request at all.
# The expected call counts are the spec's (SPEC_TRANSIENT_CALLS = 4, SPEC_MALFORMED_CALLS = 2),
# written in the support file, not read from ScreenParticipationJob.
class EngineScreeningFailurePolicyTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  def screen_with(*replies)
    @participation, @fake = screen_text!(@job, FIXTURE_CV, replies:)
  end

  def assert_failed_without_score(kind, calls)
    assert_equal calls, @fake.requests.size, "API calls for #{kind}"
    assert_equal "screening_failed", @participation.screening_state, "the operator must see 'Screening gagal'"
    assert_equal kind, @participation.screening_failure
    assert_equal 0, @participation.score_entries.count, "never a default score"
    assert_equal 0, @participation.screening_results.count
    assert_nil @participation.current_decision
    assert_equal ["failed"] * calls, @participation.screening_attempts.order(:id).pluck(:outcome), "one attempt row per call"
  end

  def conn_error = SocketError.new
  def timeout_error = Net::OpenTimeout.new

  {
    "timeout" => [-> { timeout_error }, "timeout"],
    "HTTP 429 rate limit" => [-> { gemini_error(429, "rate_limit_error") }, "api_error"],
    "HTTP 500" => [-> { gemini_error(500, "api_error") }, "api_error"],
    "HTTP 503 overloaded" => [-> { gemini_error(503, "overloaded_error") }, "api_error"],
    # The gem's real requester turns Errno::ECONNRESET into APIConnectionError (pooled_net_requester.rb:229).
    "connection reset" => [-> { conn_error }, "connection"]
  }.each do |name, (reply, kind)|
    test "#{name} on every attempt: 1 + 3 retries, then Screening gagal, no score" do
      screen_with(*Array.new(6) { instance_exec(&reply) })
      assert_failed_without_score(kind, SPEC_TRANSIENT_CALLS)
    end
  end

  test "a transient error then a good answer: exactly 2 calls and one score" do
    screen_with(gemini_error(503, "overloaded_error"), gemini_message(criteria_for(@job)))
    assert_equal 2, @fake.requests.size
    assert_equal "done", @participation.screening_state
    assert_equal 1, @participation.score_entries.count
  end

  {
    "not JSON" => ->(job) { gemini_message(nil, text: "Berikut penilaian saya: lolos") },
    "JSON without criteria" => ->(job) { gemini_message(nil, text: "{\"hasil\": []}") },
    "schema-valid but missing a requirement" => ->(job) { gemini_message(criteria_for(job).drop(1)) },
    "an extra unknown requirement id" => ->(job) { gemini_message(criteria_for(job) + [{ id: "R999999", judgement: "met", quote: "" }]) },
    "a requirement judged twice" => ->(job) { gemini_message(criteria_for(job) + [criteria_for(job).first]) },
    "a wajib rated on the 0-3 scale" => lambda { |job|
      k = Screening::Rubric.for(job).criteria.find { |c| c.tier == "wajib" }.key
      gemini_message(criteria_for(job).map { |c| c[:id] == k ? c.merge(judgement: "3") : c })
    },
    "cut off by max_tokens" => ->(job) { gemini_message(criteria_for(job), finish: "MAX_TOKENS") },
    "an empty text answer" => ->(job) { gemini_message(nil, text: "") }
  }.each do |name, reply|
    test "malformed output (#{name}) on every attempt: 1 + 1 retry, then Screening gagal, no score" do
      screen_with(*Array.new(4) { instance_exec(@job, &reply) })
      assert_failed_without_score("malformed", SPEC_MALFORMED_CALLS)
    end
  end

  test "a refusal (the model or the prompt filter declined): no retry, failed with its category" do
    screen_with(refusal_message(category: "bio"), gemini_message(criteria_for(@job)))
    assert_failed_without_score("refusal", 1)
    assert_equal "bio", @participation.screening_failure_detail
  end

  test "HTTP 401 / 400 / 404 are not retried" do
    { 401 => "authentication_error", 400 => "invalid_request_error", 404 => "not_found_error" }.each_with_index do |(status, type), i|
      @participation, @fake = screen_text!(@job, FIXTURE_CV, replies: [gemini_error(status, type)], name: "Calon Tolak #{i}")
      assert_failed_without_score("rejected", 1)
      assert_equal "HTTP #{status}", @participation.screening_failure_detail
    end
  end

  # HTTP 408 (request timeout) is a timeout, which §4.3 retries 3 times. The SDK itself classes 408
  # as retryable (the API retries 408/409/429/5xx).
  test "HTTP 408 request timeout is retried like any timeout" do
    screen_with(*Array.new(6) { gemini_error(408, "timeout_error") })
    assert_equal SPEC_TRANSIENT_CALLS, @fake.requests.size, "408 is a timeout: 1 + 3 retries"
  end

  # §4.3: "the operator sees every failure on screen, not only in a log". A 200 answer that is not
  # a Message (a proxy page, an empty object) must end in Screening gagal, not leave the CV in the
  # queue forever with nothing on screen.
  test "an unexpected answer shape ends in Screening gagal, never stuck in the queue" do
    raised = nil
    begin
      screen_with(*Array.new(6) { {} })
    rescue StandardError => e
      raised = e
    end
    participation = @participation || @job.job_applications.sole.participations.find_by!(stage: s1(@job)).reload
    assert_equal 0, participation.score_entries.count
    assert_equal "screening_failed", participation.screening_state,
                 "state stayed #{participation.screening_state.inspect} after #{raised ? "#{raised.class}: #{raised.message[0, 80]}" : 'no error'}"
  end

  test "a transient error followed by malformed answers: the malformed budget still ends in Screening gagal" do
    screen_with(timeout_error, gemini_message(nil, text: "x"), gemini_message(nil, text: "x"), gemini_message(nil, text: "x"))
    assert_equal "screening_failed", @participation.screening_state
    assert_equal 0, @participation.score_entries.count
    assert_operator @fake.requests.size, :<=, SPEC_TRANSIENT_CALLS
  end
end

class EngineScreeningGatesTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  # A requester that fails the test on ANY use: "no call" means no HTTP request was even built.
  class Tripwire
    attr_reader :calls

    def initialize = @calls = 0

    def execute(_input)
      @calls += 1
      raise "Tripwire: an HTTP request was attempted"
    end
  end

  setup { @job = screening_job }

  # D51 re-baseline (feature 09, task brief "without a key, items wait"): with no key the CV is
  # prepared locally and waits in "Menunggu pemeriksaan"; the release is refused, so nothing is sent.
  # The guard proved before (no client, no HTTP, no score) is unchanged.
  test "no API key: no client built, no HTTP request, no score; the CV waits and its release is refused" do
    wire = Tripwire.new
    Screening::AiClient.http_override = wire
    built = 0
    original = Screening::GeminiClient.method(:new)
    Screening::GeminiClient.stub(:new, ->(*a, **k) { built += 1; original.call(*a, **k) }) do
      Screening::Config.stub(:api_key, nil) do
        participation = apply_with_cv!(@job)
        drain_jobs!
        assert_equal "awaiting_release", participation.reload.screening_state
        assert(release_refusals.any? { |id, _| id == participation.id }, "control: a release was attempted and refused")
        release = AiRelease.latest_for(participation)
        error = assert_raises(AiReleases::Refused) do
          AiReleases::Release.call(release:, user: releaser, confirmed: "1", seen_sha256: release.payload_sha256)
        end
        assert_match(/No credentials are configured/, error.message)
        assert_equal 0, participation.score_entries.count
      end
    end
    assert_equal [0, 0], [wire.calls, built]
  ensure
    Screening::AiClient.http_override = nil
  end

  # D51 re-baseline: the CV now waits in "Menunggu pemeriksaan" (not "not asked"); the guard is
  # the same: no request once the key is gone.
  test "the key removed while a CV waits in the queue: no request; the CV waits, unreleasable" do
    wire = Tripwire.new
    Screening::AiClient.http_override = wire
    participation = Screening::Config.stub(:api_key, FAKE_KEY) { apply_with_cv!(@job) }
    assert_equal "queued", participation.reload.screening_state, "control: it was queued while the key existed"
    Screening::Config.stub(:api_key, nil) { drain_jobs! }
    assert_equal 0, wire.calls
    assert_equal "awaiting_release", participation.reload.screening_state
    assert_equal 0, AiReleaseAction.where(action: "released").count, "nothing was released without a key"
  ensure
    Screening::AiClient.http_override = nil
  end

  def assert_no_call_for(participation, wire)
    assert_equal 0, wire.calls, "the AI was called"
    assert_equal 0, participation.reload.score_entries.where.not(model_id: nil).count
    assert_equal 0, participation.screening_results.count
  end

  test "knocked out (a 'tidak' to a knockout question): no call" do
    wire = Tripwire.new
    with_ai(wire) do
      answers = @job.knockout_questions.to_h { |q| [q.id.to_s, "tidak"] }
      application, = submit!(@job, name: "Calon Gugur", email: "gugur@uji.example", knockout: answers, cv: pdf_upload(pdf_with_text(FIXTURE_CV)))
      participation = application.participations.find_by(stage: s1(@job))
      drain_jobs!
      assert_equal :knocked_out, Screening::Enqueue.call(participation) if participation
      assert_equal 0, wire.calls
    end
  end

  test "withdrawn while waiting in the queue: no call, and the CV does not stay 'Dalam antrean' forever" do
    wire = Tripwire.new
    with_ai(wire) do
      participation = apply_with_cv!(@job)
      assert_equal "queued", participation.reload.screening_state, "control: queued"
      participation.job_application.update_columns(status: "withdrawn")
      drain_jobs!
      assert_no_call_for(participation, wire)
      refute_equal "queued", participation.reload.screening_state,
                   "a withdrawn application keeps counting under 'Dalam antrean' on the job page"
    end
  end

  test "consent withdrawn while queued: no call" do
    wire = Tripwire.new
    with_ai(wire) do
      participation = apply_with_cv!(@job)
      participation.job_application.update_columns(consent_withdrawn_at: Time.current)
      drain_jobs!
      assert_no_call_for(participation, wire)
    end
  end

  test "consent missing: the AI is never asked, and the database refuses an application without consent" do
    wire = Tripwire.new
    with_ai(wire) do
      participation = apply_with_cv!(@job)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      error = nil
      begin
        ActiveRecord::Base.transaction(requires_new: true) { participation.job_application.update_columns(consent_at: nil) }
      rescue ActiveRecord::StatementInvalid => e
        error = e
      end
      if error
        # The database makes "a candidate's application without consent" impossible, so the AI
        # gate can never be reached with one.
        assert_includes error.message, "job_applications_consent_recorded"
      else
        assert_equal :no_consent, Screening::Enqueue.blocked_reason(participation.reload)
        participation.update_columns(screening_state: "queued")
        ScreenParticipationJob.perform_now(participation.id)
      end
      assert_equal 0, wire.calls
    end
  end

  test "stage closed while queued, or a decision already taken: no call" do
    wire = Tripwire.new
    with_ai(wire) do
      decided = apply_with_cv!(@job, name: "Calon Diputus")
      Stages::Open.call(stage: s1(@job))
      Decision.create!(participation: decided, outcome: "pass", basis: "manual", reason_code: "manual", note: "uji",
                       decided_by_id: staff_user("consultant").id, decided_at: Time.current)
      drain_jobs!
      assert_no_call_for(decided, wire)

      waiting = apply_with_cv!(@job, name: "Calon Tahap Tutup")
      assert_equal "queued", waiting.reload.screening_state, "control: queued while the stage is open"
      # The database refuses to close S1 while this CV is undecided (enforce_stage_lifecycle), so a
      # queued CV on a closed stage cannot exist; the Enqueue gate is checked in memory.
      refused_by_database { s1(@job).update_columns(status: "closed") }
      waiting.reload.stage.status = "closed"
      assert_equal :stage_closed, Screening::Enqueue.blocked_reason(waiting)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end
  end

  test "a CV with no text layer: 'CV tidak terbaca', no call, no score" do
    wire = Tripwire.new
    with_ai(wire) do
      participation = apply_with_cv!(@job, pdf: pdf_without_text)
      drain_jobs!
      assert_equal "cv_unreadable", participation.reload.screening_state
      assert_no_call_for(participation, wire)
    end
  end
end

class EngineScreeningIdempotencyTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup { @job = screening_job }

  test "the job run twice, or enqueued twice, gives one call, one result, one score entry" do
    fake = FakeGemini.new(gemini_message(criteria_for(@job)), gemini_message(criteria_for(@job)))
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      ScreenParticipationJob.perform_later(participation.id)     # a second enqueue of the same id
      assert_equal :already, Screening::Enqueue.call(participation.reload)
      assert_equal 0, Screening::Start.call(@job)[:queued], "Mulai screening on an in-flight CV queues nothing"
      drain_jobs!
      ScreenParticipationJob.perform_now(participation.id)       # and once more by hand
      assert_equal 1, fake.requests.size
      assert_equal 1, participation.screening_results.count
      assert_equal 1, participation.score_entries.count
      assert_equal 1, participation.screening_attempts.count
    end
  end

  test "Mulai screening twice after a failure re-queues once" do
    fake = FakeGemini.new(refusal_message, gemini_message(criteria_for(@job)))
    with_ai(fake) do
      participation = apply_with_cv!(@job)
      drain_jobs!
      assert_equal "screening_failed", participation.reload.screening_state
      assert_equal 1, Screening::Start.call(@job)[:queued]
      assert_equal 0, Screening::Start.call(@job)[:queued]
      drain_jobs!
      assert_equal [2, 1, 1], [fake.requests.size, participation.screening_results.count, participation.score_entries.count]
    end
  end
end
