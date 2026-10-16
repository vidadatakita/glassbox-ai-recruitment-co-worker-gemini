require "test_helper"

# D60 slice 3 (plan Part 1 §b, §d, §a.2): start, timer, answer upload and expiry. Every timing test
# uses travel_to and the exact boundary plus one second, because "about 48 hours" proves nothing.
class TechnicalTests::FlowTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @t0 = Time.zone.parse("2026-10-05 09:00:00")
    @job = travel_to(@t0) { technical_test_job }
    @application, = travel_to(@t0) { applicant!(@job) }
    @s2 = s2_of(@application)
    @version = TechnicalTestCase.current_for(@job)
  end

  # --- start -----------------------------------------------------------------------------------

  test "start pins the newest approved version and sets due_at = start + its limit, on the server clock" do
    attempt = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    assert_equal @version.id, attempt.test_case_id
    assert_equal @t0 + 1.hour, attempt.started_at
    assert_equal @t0 + 1.hour + 35.minutes, attempt.due_at
    assert_equal 120, attempt.grace_seconds, "the 2-minute grace is recorded on the attempt"
  end

  test "a second start (refresh, another device) returns the same attempt with the same due_at" do
    first = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    again = travel_to(@t0 + 1.hour + 20.minutes) { TechnicalTests::Start.call(application: @application) }
    assert_equal first.id, again.id
    assert_equal first.due_at, again.reload.due_at
    assert_equal 1, TestAttempt.where(participation: @s2).count
  end

  test "start AT start_by (submit + 48 h) is accepted" do
    attempt = travel_to(@t0 + 48.hours) { TechnicalTests::Start.call(application: @application) }
    assert attempt.persisted?
  end

  test "start one second after start_by is refused and writes nothing" do
    error = assert_raises(TechnicalTests::Start::Refused) do
      travel_to(@t0 + 48.hours + 1.second) { TechnicalTests::Start.call(application: @application) }
    end
    assert_match "deadline to start", error.message
    assert_equal 0, TestAttempt.count
  end

  test "the database refuses a start after the 48-hour window even when the service is bypassed" do
    late = @t0 + 48.hours + 1.second
    error = refused_by_database do
      TestAttempt.create!(participation: @s2, test_case: @version, started_at: late, due_at: late + 35.minutes)
    end
    assert_match "48-hour start window", error.message
  end

  test "the database refuses a due_at that is not start + the version's limit" do
    start = @t0 + 1.hour
    error = refused_by_database do
      TestAttempt.create!(participation: @s2, test_case: @version, started_at: start, due_at: start + 50.minutes)
    end
    assert_match "due_at must be started_at + 35 minutes", error.message
  end

  test "control: the database accepts a correct start" do
    start = @t0 + 1.hour
    assert TestAttempt.create!(participation: @s2, test_case: @version, started_at: start, due_at: start + 35.minutes).persisted?
  end

  test "start is refused after a withdrawal, and on a participation that is already decided" do
    travel_to(@t0 + 49.hours) { TechnicalTests::Expire.call(@application) } # no_show decision
    assert_raises(TechnicalTests::Start::Refused) { travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) } }

    other, = travel_to(@t0) { applicant!(@job) }
    other.update!(consent_withdrawn_at: @t0 + 1.minute)
    error = assert_raises(TechnicalTests::Start::Refused) { travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: other) } }
    assert_match "withdrawn", error.message
  end

  test "the database refuses a start on a decided participation" do
    travel_to(@t0 + 49.hours) { TechnicalTests::Expire.call(@application) }
    start = @t0 + 1.hour
    error = refused_by_database do
      TestAttempt.create!(participation: @s2.reload, test_case: @version, started_at: start, due_at: start + 35.minutes)
    end
    assert_match(/attendance is no_show|already decided/, error.message)
  end

  test "the database refuses a start on a participation decided while attendance is still pending (knockout)" do
    knocked, = travel_to(@t0) { applicant!(@job, knockout: answers_for(@job).merge(@job.knockout_questions.first.id.to_s => "tidak")) }
    s2 = s2_of(knocked)
    assert_equal ["pending", "knockout"], [s2.attendance, s2.current_decision.reason_code]
    start = @t0 + 1.hour
    error = refused_by_database do
      TestAttempt.create!(participation: s2, test_case: @version, started_at: start, due_at: start + 35.minutes)
    end
    assert_match "already decided", error.message
  end

  test "no technical test on a job without the gate" do
    job = portal_job
    open_portal(job)
    application, = submit!(job, email: "tanpa.tes@uji.example")
    assert_equal :none, TechnicalTests::Status.new(application).state
    assert_raises(TechnicalTests::Start::Refused) { TechnicalTests::Start.call(application:) }
  end

  # --- answer ----------------------------------------------------------------------------------

  test "an answer at due_at + 120 s is accepted and marks attendance attended" do
    started = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    attempt = travel_to(started.due_at + 120.seconds) { TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file) }
    assert_equal started.due_at + 120.seconds, attempt.answered_at
    assert_equal "xlsx", attempt.answer_kind
    assert_equal "scan_unavailable", attempt.answer_scan_state
    assert_equal attempt.answer_file.blob_id, attempt.answer_blob_id
    assert_equal "attended", @s2.reload.attendance
  end

  test "an answer at due_at + 121 s is refused and writes nothing" do
    started = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(started.due_at + 121.seconds) { TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file) }
    end
    assert_match "The technical test time is up", error.message
    assert_nil started.reload.answered_at
    assert_equal "pending", @s2.reload.attendance
    assert_not started.answer_file.attached?
  end

  test "the database refuses an answer time past due_at + the recorded grace" do
    started = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(xlsx_bytes), filename: "jawaban.xlsx")
    started.answer_file.attach(blob)
    error = refused_by_database do
      started.update_columns(answered_at: started.due_at + 121.seconds, answer_blob_id: blob.id, answer_kind: "xlsx",
                             answer_sha256: "x", answer_bytes: 10, answer_scan_state: "scan_unavailable")
    end
    assert_match "test_attempts_answer_in_time", error.message
  end

  test "an answer before start is refused" do
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) { TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file) }
    assert_match "has not been started", error.message
  end

  test "one answer, final: a second upload is refused; the database refuses changing it or its file" do
    attempt = answered!(@application, at: @t0 + 1.hour)
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 1.minute) { TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file) }
    end
    assert_match "only once", error.message

    db = refused_by_database { attempt.update_columns(answer_sha256: "lain") }
    assert_match "final once sent", db.message
    file_error = refused_by_database { attempt.answer_file.attachment.update_columns(blob_id: attempt.answer_blob_id) }
    assert_match "sent test answer never changes", file_error.message
  end

  test "the answer is judged by content with the version's types: pdf refused when the version allows only xlsx" do
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 1.minute) { TechnicalTests::SubmitAnswer.call(application: @application, file: upload(PDF_BYTES, "jawaban.pdf")) }
    end
    assert_match "not allowed", error.message
  end

  test "a macro workbook renamed to .xlsx is refused" do
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    macro = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("[Content_Types].xml")
      zip.write('<Types><Override ContentType="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/></Types>')
      zip.put_next_entry("xl/vbaProject.bin")
      zip.write("VBA")
    end.string
    assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 1.minute) { TechnicalTests::SubmitAnswer.call(application: @application, file: upload(macro, "jawaban.xlsx")) }
    end
    assert_nil TestAttempt.last.answered_at
  end

  test "the answer cap is 10 MB, not the case file's 20 MB" do
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    big = upload("a" * (10.megabytes + 1), "jawaban.xlsx")
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 1.minute) { TechnicalTests::SubmitAnswer.call(application: @application, file: big) }
    end
    assert_match "larger than 10 MB", error.message
  end

  test "an infected scan result refuses the answer" do
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    previous = TestCases::FileScan.adapter
    TestCases::FileScan.adapter = Class.new { def call(_io) = "infected" }.new
    assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 1.minute) { TechnicalTests::SubmitAnswer.call(application: @application, file: answer_file) }
    end
    assert_nil TestAttempt.last.answered_at
  ensure
    TestCases::FileScan.adapter = previous
  end

  # --- expiry (no-show, rule 5) ----------------------------------------------------------------

  test "not started by start_by: no_show and a rule decision, once" do
    assert_not travel_to(@t0 + 48.hours) { TechnicalTests::Expire.call(@application) }, "at start_by nothing expires"
    assert travel_to(@t0 + 48.hours + 1.second) { TechnicalTests::Expire.call(@application) }
    @s2.reload
    assert_equal "no_show", @s2.attendance
    decision = @s2.current_decision
    assert_equal %w[eliminate rule no_show], [decision.outcome, decision.basis, decision.reason_code]
    assert_empty @s2.score_entries, "rule 5: a no-show has no score, never a zero"
    assert_not travel_to(@t0 + 50.hours) { TechnicalTests::Expire.call(@application) }, "idempotent"
    assert_equal 1, @s2.decisions.count
  end

  test "started with no answer: expires one second after due_at + grace, not before" do
    attempt = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @application) }
    assert_not travel_to(attempt.due_at + 120.seconds) { TechnicalTests::Expire.call(@application) }
    assert travel_to(attempt.due_at + 121.seconds) { TechnicalTests::Expire.call(@application) }
    assert_equal "no_show", @s2.reload.current_decision.reason_code
  end

  test "an answered test never expires" do
    answered!(@application, at: @t0 + 1.hour)
    assert_not travel_to(@t0 + 60.hours) { TechnicalTests::Expire.call(@application) }
    assert_nil @s2.reload.current_decision
  end

  test "the page state follows the clock even before the expiry write runs" do
    status = TechnicalTests::Status.new(@application, now: @t0 + 48.hours + 1.second)
    assert_equal :expired, status.state
    assert_equal "pending", @s2.reload.attendance, "only the display moved; Expire writes the record"
  end

  test "S1 currently eliminated: the no-show fact is recorded but no S2 decision (gate_eliminated at close)" do
    s1 = s1_of(@application)
    travel_to(@t0 + 1.hour) do
      s1.update!(attendance: "attended")
      add_score(s1, 20)
      decide!(s1, outcome: "eliminate", reason_code: "below_threshold")
    end
    travel_to(@t0 + 49.hours) { TechnicalTests::Expire.call(@application) }
    assert_equal "no_show", @s2.reload.attendance
    assert_nil @s2.current_decision
  end

  test "a no-show while the gate is a draft gets its decision on the first run after the gate opens" do
    job = travel_to(@t0) { technical_test_job(open_gate: false) }
    application, = travel_to(@t0) { applicant!(job) }
    travel_to(@t0 + 49.hours) { TechnicalTests::Expire.call(application) }
    s2 = s2_of(application)
    assert_equal "no_show", s2.attendance
    assert_nil s2.current_decision, "no decision on a draft stage (D37)"
    travel_to(@t0 + 50.hours) do
      Gates::Open.call(stage: s1_of(application).stage)
      TechnicalTests::Expire.call(application)
    end
    assert_equal "no_show", s2.reload.current_decision.reason_code
  end

  test "the sweep finds every expired gated test and is idempotent" do
    second, = travel_to(@t0) { applicant!(@job) }
    assert_equal 2, travel_to(@t0 + 49.hours) { TechnicalTests::Expire.sweep }
    assert_equal 0, travel_to(@t0 + 49.hours) { TechnicalTests::Expire.sweep }
    assert_equal "no_show", s2_of(second).current_decision.reason_code
  end
end
