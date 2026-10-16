require "test_helper"

# Blueprint §4.3 and §5.2: timeout or API error -> 3 retries with increasing wait, then
# "Screening gagal"; malformed output -> 1 retry, then the same; a refusal -> failed at once with
# its category shown. On EVERY failure path: no ScoreEntry, no ScreeningResult, no Decision.
class Screening::FailurePolicyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
  end

  # Runs the screening job and every retry it schedules, as Solid Queue would, without waiting.
  def screen(*replies)
    @fake = FakeGemini.new(*replies)
    with_ai(@fake) do
      @participation = apply_with_cv!(@job)
      # D51 B: the first run prepares the text and stops; a reviewer releases it; then the call.
      perform_enqueued_jobs
      release_held!
      10.times do
        break if enqueued_jobs.empty?

        perform_enqueued_jobs(at: 1.year.from_now)
      end
    end
    @participation.reload
  end

  def assert_failed_without_score(kind)
    assert_equal "screening_failed", @participation.screening_state
    assert_equal kind, @participation.screening_failure
    assert_empty @participation.score_entries, "a failure must never leave a score"
    assert_empty @participation.screening_results
    assert_nil @participation.current_decision
  end

  test "a timeout on every attempt: 4 calls (1 + 3 retries), then Screening gagal, no score" do
    screen(*Array.new(4) { Net::OpenTimeout.new })
    assert_equal 4, @fake.requests.size
    assert_failed_without_score("timeout")
    assert_equal %w[failed failed failed failed], @participation.screening_attempts.order(:id).pluck(:outcome)
  end

  test "the retry waits grow (increasing wait, §4.3)" do
    @fake = FakeGemini.new(*Array.new(4) { [503, { type: "error", error: { type: "overloaded_error", message: "x" } }] })
    waits = []
    with_ai(@fake) do
      @participation = apply_with_cv!(@job)
      perform_enqueued_jobs # D51 B: prepare, then release; the retries below are the released call's
      release_held!
      # Execute one job at a time by hand, reading the wait of the retry each attempt schedules.
      3.times do
        data = enqueued_jobs.last
        enqueued_jobs.clear
        ActiveJob::Base.execute(data.select { |k, _| k.is_a?(String) })
        retry_job = enqueued_jobs.last
        waits << (retry_job[:at] - Time.current.to_f) if retry_job && retry_job[:at]
      end
    end
    assert_equal 3, waits.size, "three retries were scheduled"
    assert_operator waits[1], :>, waits[0]
    assert_operator waits[2], :>, waits[1]
  end

  test "an API error (HTTP 503) on every attempt also ends in Screening gagal after 4 calls" do
    screen(*Array.new(4) { [503, { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }] })
    assert_equal 4, @fake.requests.size
    assert_failed_without_score("api_error")
    assert_equal "HTTP 503", @participation.screening_failure_detail
  end

  test "a timeout followed by a good answer: screened, with the failed try on record" do
    screen(Net::OpenTimeout.new, gemini_message(criteria_for(@job)))
    assert_equal 2, @fake.requests.size
    assert_equal "done", @participation.screening_state
    assert_equal 1, @participation.score_entries.count
    assert_equal %w[failed succeeded], @participation.screening_attempts.order(:id).pluck(:outcome)
  end

  test "malformed output twice: 2 calls (1 + 1 retry), then Screening gagal, no score" do
    screen(gemini_message(nil, text: "bukan json"), gemini_message(nil, text: "{\"criteria\": []}"))
    assert_equal 2, @fake.requests.size
    assert_failed_without_score("malformed")
  end

  test "an answer that misses a requirement, or judges a wajib on the 0-3 scale, is malformed" do
    short = criteria_for(@job).drop(1)
    wrong = criteria_for(@job).map { |c| Requirement.find(c[:id].delete("R")).tier == "wajib" ? c.merge(judgement: "2") : c }
    screen(gemini_message(short), gemini_message(wrong))
    assert_failed_without_score("malformed")
  end

  test "a cut-off answer (max_tokens) counts as malformed" do
    screen(gemini_message(criteria_for(@job), finish: "MAX_TOKENS"), gemini_message(criteria_for(@job), finish: "MAX_TOKENS"))
    assert_equal 2, @fake.requests.size
    assert_failed_without_score("malformed")
  end

  test "a refusal fails at once (no retry) and shows its category to staff" do
    screen(refusal_message(category: "cyber"))
    assert_equal 1, @fake.requests.size
    assert_failed_without_score("refusal")
    assert_equal "cyber", @participation.screening_failure_detail
    assert_includes ScreeningBoard.failure_label(@participation), "The AI declined to assess this CV (cyber)"
  end

  test "a rejected request (HTTP 401, wrong key) fails at once, no retry" do
    screen([401, { type: "error", error: { type: "authentication_error", message: "API key not valid" } }])
    assert_equal 1, @fake.requests.size
    assert_failed_without_score("rejected")
    assert_equal "HTTP 401", @participation.screening_failure_detail
  end

  test "Mulai screening retries a failed screening, which can then succeed" do
    screen(refusal_message)
    assert_equal "screening_failed", @participation.screening_state
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      assert_equal 1, Screening::Start.call(@job)[:queued]
      perform_enqueued_jobs
    end
    assert_equal "done", @participation.reload.screening_state
  end

  test "a CV file missing from storage ends in Screening gagal (cv_file), with an attempt row and no call" do
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job)
      blob = @participation.job_application.cv.blob
      ActiveStorage::Blob.service.delete(blob.key)
      perform_enqueued_jobs
    end
    @participation.reload
    assert_empty @fake.requests
    assert_failed_without_score("cv_file")
    assert_equal "FileNotFoundError", @participation.screening_failure_detail
    assert_equal %w[failed], @participation.screening_attempts.pluck(:outcome)
  end

  test "an unexpected error ends in Screening gagal with the error class, an attempt row, and is re-raised" do
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job)
      Screening::Rubric.stub(:for, ->(_job) { raise NoMethodError, "boom" }) do
        assert_raises(NoMethodError) { perform_enqueued_jobs }
      end
    end
    @participation.reload
    assert_failed_without_score("unexpected")
    assert_equal "NoMethodError", @participation.screening_failure_detail
    assert_equal 1, @participation.screening_attempts.where(error_kind: "unexpected").count
    label = ScreeningBoard.failure_label(@participation)
    assert_includes label, "system fault, not because of the CV"
    refute_includes label, "NoMethodError", "the class name stays in the attempt history and the log, not on screen"
  end

  # Test engine run 2, mutant R06: the non-Message check must give the MALFORMED path (1 retry),
  # not the catch-all (no retry). A second, good answer proves the retry happened.
  test "a 200 reply that is not a message is malformed: retried once, then screened" do
    screen({}, gemini_message(criteria_for(@job)))
    assert_equal 2, @fake.requests.size
    assert_equal "done", @participation.screening_state
    assert_equal [%w[failed malformed], %w[succeeded] + [nil]], @participation.screening_attempts.order(:id).pluck(:outcome, :error_kind)
  end

  # ADR 0004: fail closed. Personal data the patterns miss stops the CV before any call. Since D51
  # (feature 09) the CV waits on the reviewer's release screen with the finding stored; that
  # version cannot be released (service and database), and a reviewer's cut of the line makes a
  # clean version that can. The leak is placed INSIDE an evidence section: D51 A drops the header
  # before redaction, so a header leak no longer reaches the check at all (asserted below too).
  test "personal data left after redaction: no call, the version cannot be released, a reviewer's cut can" do
    leaky = FIXTURE_CV.sub("Mengelola stok", "Lhr. Bdg 01-02-1990\nMengelola stok")
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text: leaky)
      perform_enqueued_jobs
      assert_empty release_held!, "a version with residual findings is never released"
    end
    @participation.reload
    assert_empty @fake.requests, "nothing may be sent when personal data is still visible"
    assert_equal "awaiting_release", @participation.screening_state
    release = AiRelease.latest_for(@participation)
    assert_equal %w[birth_date], release.residual_categories
    reviewer = staff_user("reviewer")
    error = assert_raises(AiReleases::Refused) do
      with_ai(@fake) { AiReleases::Release.call(release:, user: reviewer, confirmed: "1", seen_sha256: release.payload_sha256) }
    end
    assert_includes error.message, "Personal data"
    leak_line = release.lines.index { |l| l.include?("01-02-1990") }
    cut = AiReleases::Cut.call(release:, user: reviewer, line_numbers: [leak_line])
    assert_empty cut.residual_categories
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      screen_and_release!(reviewer:)
    end
    assert_equal "done", @participation.reload.screening_state
    assert_equal 1, @fake.requests.size
    refute_includes @fake.bodies.first, "01-02-1990"
  end

  test "a leak in the header never reaches the check: D51 A drops the header before redaction" do
    leaky = FIXTURE_CV.sub("PENDIDIKAN", "Lhr. Bdg 01-02-1990\nPENDIDIKAN")
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text: leaky)
      perform_enqueued_jobs
    end
    release = AiRelease.latest_for(@participation.reload)
    assert_empty release.residual_categories
    refute_includes release.payload_text, "01-02-1990"
  end

  # D51 A: a CV with no recognisable evidence section is not sent ("Perlu cek manual").
  test "a CV with no evidence section is not sent: 'Perlu cek manual' (no_evidence_section), no call, no score" do
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text: "DATA PRIBADI\nNama: Rina Pratiwi\nHobi membaca dan berkebun di rumah orang tua\nSuka bersepeda setiap minggu pagi")
      perform_enqueued_jobs
    end
    @participation.reload
    assert_empty @fake.requests
    assert_failed_without_score("no_evidence_section")
    assert_equal "No experience/education section found", @participation.screening_failure_detail
    assert_includes ScreeningBoard.failure_label(@participation), "Manual check needed"
    assert_empty AiRelease.where(participation: @participation)
  end

  # F-23: a CV that redaction has emptied is never judged (it would fail every wajib on nothing).
  test "an emptied CV is not sent: 'Perlu cek manual' (too little text), no call, no score" do
    @fake = FakeGemini.new
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text: "PENGALAMAN KERJA\nRina Pratiwi\nNIK: 3275011203950004\nAgama: Islam\nJenis Kelamin: Perempuan\nStatus Pernikahan: Menikah")
      perform_enqueued_jobs
    end
    @participation.reload
    assert_empty @fake.requests
    assert_failed_without_score("too_little_text")
    assert_includes ScreeningBoard.failure_label(@participation), "too little CV content"
  end
end
