require "test_helper"
require_relative "run2_support"

# Test engine 07 run 2: service and database attacks on the slice 1-2 fixes (F-02..F-06) and on
# slices 3-5 (clock, answer, expiry, notices, scoring). Times use travel_to and exact boundaries.
class Engine07Run2ServicesTest < ActiveSupport::TestCase
  include Run2Support

  setup do
    ActionMailer::Base.deliveries.clear
    @t0 = Time.zone.parse("2026-10-06 08:00:00")
    @job = travel_to(@t0) { r2_job }
    @app, @token = travel_to(@t0) { r2_apply(@job) }
  end

  # ---- fixes: F-02 digest ----------------------------------------------------------------------
  test "F-02 fix: approval with a stale, missing or other version's digest is refused; the right digest approves" do
    job = e7_brief
    tc = e7_save(job, instructions: "Dibaca HR").test_case
    seen = tc.content_digest
    hr = staff_user("hr_pic")
    { "file only" => { file: e7_upload(e7_xlsx([["lain"]]), "lain.xlsx") },
      "anchor only" => {} }.each do |label, change|
      params = e7_params(job, file: nil, instructions: "Dibaca HR").merge(change)
      params[:criteria]["0"][:anchor_5] = "Anchor diubah" if label == "anchor only"
      params[:file] = nil
      params[:case_file] = change[:file] if change[:file]
      assert TestCases::SaveVersion.call(job:, actor: staff_user("consultant"), params:).ok?
      refute TestCases::Approve.call(test_case: tc.reload, actor: hr, seen_digest: seen).ok?, "#{label}: stale digest approved"
      seen = tc.reload.content_digest
    end
    refute TestCases::Approve.call(test_case: tc.reload, actor: hr, seen_digest: "").ok?, "empty digest approved"
    refute TestCases::Approve.call(test_case: tc.reload, actor: hr, seen_digest: Digest::SHA256.hexdigest("x")).ok?
    assert TestCases::Approve.call(test_case: tc.reload, actor: hr, seen_digest: seen).ok?
  end

  # ---- fixes: F-06 gate_closing ------------------------------------------------------------------
  test "F-06 fix: gate_eliminated refused on an open gate; the setting is cleared after Gates::Close in the same transaction" do
    other, = travel_to(@t0) { r2_apply(@job, name: "Sinta Uji") }
    r2_s1_decide!(@app, "eliminate")
    s2 = r2_s2(@app)
    error = refused_by_database { Decision.create!(participation: s2, outcome: "eliminate", basis: "rule", reason_code: "gate_eliminated", decided_at: Time.current) }
    assert_match "only while the gate closes", error.message
    assert_equal "", ActiveRecord::Base.connection.select_value("SELECT coalesce(current_setting('glassbox.gate_closing', true), '')").to_s
    # The setting is a convention (house pattern of glassbox.stage_change_id): raw SQL can name it.
    # Stated, not a defect: the same as every transaction-local "named change" guard in this app.
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("SELECT set_config('glassbox.gate_closing', '#{s2.stage_id}', true)")
      Decision.create!(participation: s2, outcome: "eliminate", basis: "rule", reason_code: "gate_eliminated", decided_at: Time.current)
      raise ActiveRecord::Rollback
    end
    assert other
  end

  # ---- fixes: F-04 reopen ------------------------------------------------------------------------
  test "F-04 fix: an S1 correction after close reopens S2 as a manual review, once; the gate is open, not passed" do
    out, = travel_to(@t0) { r2_apply(@job, name: "Bayu Uji") }
    travel_to(@t0 + 1.hour) do
      r2_s1_decide!(out, "eliminate")
      r2_s1_decide!(@app, "pass")
      attempt = r2_answer(@app)
      r2_score!(attempt, [5, 5])
    end
    travel_to(@t0 + 49.hours) do
      TechnicalTests::Expire.call(out)
      Gates::Close.call(stage: @job.stages.find_by!(code: "S1"))
    end
    gate_row = r2_s2(out).current_decision
    assert_equal "gate_eliminated", gate_row.reason_code
    corrector = r2_reviewer
    Decision.create!(participation: r2_s1(out), outcome: "pass", basis: "manual", reason_code: "objection_upheld",
                     note: "Keberatan diterima", decided_by_id: corrector.id, decided_at: Time.current, supersedes: r2_s1(out).current_decision)
    reopened = r2_s2(out).current_decision
    assert_equal %w[review manual gate_reopened_after_s1_correction], [reopened.outcome, reopened.basis, reopened.reason_code]
    assert_equal gate_row.id, reopened.supersedes_id
    assert_equal corrector.id, reopened.decided_by_id
    assert_equal :open, Gates::Result.of(r2_s1(out).current_decision, reopened)
    # a second S1 correction (pass -> review) does not stack another S2 row
    Decision.create!(participation: r2_s1(out), outcome: "review", basis: "manual", reason_code: "x", note: "lagi",
                     decided_by_id: corrector.id, decided_at: Time.current, supersedes: r2_s1(out).current_decision)
    assert_equal reopened.id, r2_s2(out).current_decision.id
    # the candidate is not told "belum lolos" for the gate while it is reopened
    gate = CandidateStatus.new(out.reload).steps.find { |s| s.label.start_with?(Stage::GATES["screening"]) }
    refute_equal :not_passed, gate.state, "reopened candidate still shown as not passed: #{gate.label}"
  end

  # ---- slice 3: clock ---------------------------------------------------------------------------
  test "start: replay returns the same attempt; at start_by accepted is pinned on the server clock; +1 s refused" do
    a = travel_to(@t0 + 48.hours) { TechnicalTests::Start.call(application: @app) }
    assert_equal @t0 + 48.hours, a.started_at
    assert_equal a.started_at + 35.minutes, a.due_at
    b = travel_to(@t0 + 48.hours + 10.minutes) { TechnicalTests::Start.call(application: @app) }
    assert_equal [a.id, a.due_at], [b.id, b.due_at]
    other, = travel_to(@t0) { r2_apply(@job, name: "Telat Uji") }
    assert_raises(TechnicalTests::Start::Refused) { travel_to(@t0 + 48.hours + 1.second) { TechnicalTests::Start.call(application: other) } }
    assert_nil r2_attempt(other)
  end

  test "DB: due_at longer than the limit, a start before submit and a second attempt are refused" do
    s2 = r2_s2(@app)
    v = TechnicalTestCase.current_for(@job)
    t = (@t0 + 1.hour).floor(6)
    assert_match "due_at must be", refused_by_database { TestAttempt.create!(participation: s2, test_case: v, started_at: t, due_at: t + 36.minutes) }.message
    TestAttempt.create!(participation: s2, test_case: v, started_at: t, due_at: t + 35.minutes)
    refused_by_database { TestAttempt.create!(participation: s2, test_case: v, started_at: t, due_at: t + 35.minutes) }
  end

  test "a version approved mid-test does not change a running candidate's version, file or limit" do
    attempt = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @app) }
    v1 = attempt.test_case
    v2 = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"),
                                     params: e7_params(@job, time_limit_minutes: "60", new_version_reason: "Lebih lama", answer_types: %w[xlsx])).test_case
    assert TestCases::Approve.call(test_case: v2, actor: staff_user("hr_pic")).ok?
    assert_equal v1.id, attempt.reload.test_case_id
    status = travel_to(@t0 + 1.hour + 36.minutes) { TechnicalTests::Status.new(@app.reload) }
    assert_equal v1.id, status.version.id
    assert_equal 35, status.time_limit
    pdf = r2_pdf("1 0 obj<< /Type /Catalog >>endobj")
    travel_to(@t0 + 1.hour + 10.minutes) { TechnicalTests::SubmitAnswer.call(application: @app, file: e7_upload(pdf, "jawaban.pdf")) }
    assert_equal "pdf", attempt.reload.answer_kind, "the pinned v1 allows pdf even though v2 does not"
  end

  # ---- slice 3: answer --------------------------------------------------------------------------
  test "answer: at due+grace accepted; +1 s refused; second answer refused and the first unchanged" do
    late, = travel_to(@t0) { r2_apply(@job, name: "Batas Uji") }
    a = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @app) }
    b = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: late) }
    travel_to(a.due_at + 120.seconds) { TechnicalTests::SubmitAnswer.call(application: @app, file: e7_upload(e7_xlsx, "j.xlsx")) }
    assert_equal a.due_at + 120.seconds, a.reload.answered_at
    sha = a.answer_sha256
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(a.due_at + 121.seconds) { TechnicalTests::SubmitAnswer.call(application: late, file: e7_upload(e7_xlsx, "j.xlsx")) }
    end
    assert_match "time is up", error.message
    assert_nil b.reload.answered_at
    assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(a.due_at) { TechnicalTests::SubmitAnswer.call(application: @app, file: e7_upload(e7_xlsx([["dua"]]), "j.xlsx")) }
    end
    assert_equal sha, a.reload.answer_sha256
  end

  def refused_answer(bytes, name)
    app, = travel_to(@t0) { r2_apply(@job, name: "File Uji") }
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: app) }
    error = assert_raises(TechnicalTests::SubmitAnswer::Refused) do
      travel_to(@t0 + 1.hour + 5.minutes) { TechnicalTests::SubmitAnswer.call(application: app, file: e7_upload(bytes, name)) }
    end
    assert_nil r2_attempt(app).answered_at
    error.message
  end

  def accepted_answer?(bytes, name)
    app, = travel_to(@t0) { r2_apply(@job, name: "File Uji") }
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: app) }
    travel_to(@t0 + 1.hour + 5.minutes) { TechnicalTests::SubmitAnswer.call(application: app, file: e7_upload(bytes, name)) }
    true
  rescue TechnicalTests::SubmitAnswer::Refused
    false
  end

  test "answer files: 10 MB exact accepted, +1 byte refused; types outside the version, renamed xlsm, vbaProject refused" do
    exact = "%PDF-1.4\n" + (" " * (10_485_760 - 9))
    assert_equal 10_485_760, exact.bytesize
    assert accepted_answer?(exact, "a.pdf"), "10 MB exactly refused"
    assert_match "larger than", refused_answer(exact + " ", "a.pdf")
    docx = Zip::OutputStream.write_buffer { |z| z.put_next_entry("word/document.xml"); z.write("<w:document/>"); z.put_next_entry("[Content_Types].xml"); z.write("<Types/>") }.string
    refused_answer(docx, "a.docx")
    refused_answer(e7_xlsx, "a.xlsm")
    require "zip"
    vba = Zip::OutputStream.write_buffer do |z|
      Zip::File.open_buffer(e7_xlsx) { |zip| zip.entries.each { |e| z.put_next_entry(e.name); z.write(e.get_input_stream.read) } }
      z.put_next_entry("xl/vbaProject.bin"); z.write("VBA")
    end.string
    refused_answer(vba, "a.xlsx")
  end

  test "answer PDF: plain-text active names refused (/JavaScript /JS /OpenAction /AA /Launch /EmbeddedFile)" do
    %w[/JavaScript /JS /OpenAction /AA /Launch /EmbeddedFile].each do |name|
      assert_match "script", refused_answer(r2_pdf("1 0 obj<< #{name} (x) >>endobj"), "a.pdf"), name
    end
  end

  # The record (Slices 3-5 part 8) states these pass: probes, green while they pass.
  test "PROBE (disclosed in the record): hex-escaped /J#61vaScript and a name inside a compressed stream pass" do
    assert accepted_answer?(r2_pdf("1 0 obj<< /OpenActio#6e << /S /J#61vaScript /J#53 (app.alert(1)) >> >>endobj"), "a.pdf")
    stream = Zlib::Deflate.deflate("<< /S /JavaScript /JS (app.alert(1)) >>")
    assert accepted_answer?(r2_pdf("2 0 obj<< /Type /ObjStm /Filter /FlateDecode /Length #{stream.bytesize} >>stream\n#{stream}\nendstream endobj"), "a.pdf")
  end

  test "answer CSV: =, +, @, quoted and leading-space formulas refused; negative numbers accepted (control)" do
    ["=1+1,a\n", "a,+cmd\n", "a;@SUM(A1)\n", "\"=HYPERLINK(\"\"x\"\")\",1\n", "  =1\n", "-cmd|' /C calc'!A0\n"].each do |csv|
      assert_match "formula", refused_answer(csv, "a.csv"), csv.inspect
    end
    assert accepted_answer?("kode,selisih\nBRG-1,-8\nBRG-2,-0.5\n", "a.csv")
  end

  # SubmitAnswer#active_content! claims to refuse "a cell that Excel would evaluate as a formula (DDE)".
  # OWASP's CSV-injection payloads include "-2+3+cmd|' /C calc'!A0" (Excel evaluates it), and a
  # UTF-8 BOM before "=" (Excel strips the BOM, then evaluates the formula).
  test "FINDING: CSV formulas that start with '-<digit>' or follow a UTF-8 BOM pass the answer check" do
    passed = { "-2+3+cmd|' /C calc'!A0" => "-2+3+cmd|' /C calc'!A0\n",
               "BOM =" => "﻿=cmd|' /C calc'!A0,1\n".b }.select { |_, csv| accepted_answer?(csv, "a.csv") }
    assert_empty passed.keys, "accepted as a candidate answer: #{passed.keys.inspect}"
  end

  # ---- slice 3: expiry --------------------------------------------------------------------------
  test "expiry: not started -> no_show at start_by+1 s by tick and by the lazy path, idempotent, never a score" do
    lazy, = travel_to(@t0) { r2_apply(@job, name: "Lazy Uji") }
    travel_to(@t0 + 48.hours) { TechnicalTests::Tick.call; assert_equal "pending", r2_s2(@app).attendance }
    travel_to(@t0 + 48.hours + 1.second) do
      TechnicalTests::Tick.call
      TechnicalTests::Tick.call
      TechnicalTests::Expire.call(lazy)
      TechnicalTests::Expire.call(lazy)
    end
    [@app, lazy].each do |a|
      s2 = r2_s2(a)
      assert_equal "no_show", s2.attendance
      assert_equal 1, s2.decisions.count, "idempotent"
      assert_equal "no_show", s2.current_decision.reason_code
      assert_equal 0, s2.score_entries.count, "a no-show got a score"
    end
  end

  test "expiry after a start with no answer: due+grace not yet, +1 s no_show; an S1-eliminated candidate gets the fact, no decision (B-6), then gate_eliminated" do
    out, = travel_to(@t0) { r2_apply(@job, name: "Gugur Uji") }
    a = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: @app) }
    o = travel_to(@t0 + 1.hour) { r2_s1_decide!(out, "eliminate"); TechnicalTests::Start.call(application: out) }
    travel_to(a.due_at + 120.seconds) { TechnicalTests::Tick.call }
    assert_equal "pending", r2_s2(@app).attendance
    travel_to(o.due_at + 121.seconds) { TechnicalTests::Tick.call; TechnicalTests::Expire.call(out) }
    assert_equal "no_show", r2_s2(@app).current_decision.reason_code
    assert_equal "no_show", r2_s2(out).attendance
    assert_nil r2_s2(out).current_decision, "B-6: no S2 no-show decision for an S1-eliminated candidate"
    r2_s1_decide!(@app, "pass")
    travel_to(@t0 + 50.hours) { Gates::Close.call(stage: @job.stages.find_by!(code: "S1")) }
    assert_equal "gate_eliminated", r2_s2(out).current_decision.reason_code
    assert_equal 0, ScoreEntry.where(participation: [r2_s2(out), r2_s2(@app)]).count
  end

  test "an answered test never expires" do
    a = travel_to(@t0 + 1.hour) { r2_answer(@app) }
    travel_to(a.due_at + 3.days) { TechnicalTests::Tick.call; TechnicalTests::Expire.call(@app) }
    assert_equal "attended", r2_s2(@app).attendance
    assert_nil r2_s2(@app).current_decision
  end

  # ---- slice 4: notices -------------------------------------------------------------------------
  test "notices: reminder not at 24 h - 1 s, once at 24 h, never after a start; receipt once; outcome only after close" do
    started, = travel_to(@t0) { r2_apply(@job, name: "Mulai Uji") }
    travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: started) }
    kinds = ->(a) { MailDelivery.where(job_application: a).order(:id).pluck(:kind) }
    travel_to(@t0 + 24.hours - 1.second) { TechnicalTests::Tick.call }
    refute_includes kinds.(@app), "test_reminder"
    travel_to(@t0 + 24.hours) { 3.times { TechnicalTests::Tick.call } }
    assert_equal 1, kinds.(@app).count("test_reminder")
    travel_to(@t0 + 24.hours) { TechnicalTests::Notices.reminder(started.reload, now: @t0 + 24.hours) }
    refute_includes kinds.(started), "test_reminder", "reminder sent to a candidate who already started"
    travel_to(@t0 + 1.hour + 5.minutes) do
      TechnicalTests::SubmitAnswer.call(application: started, file: e7_upload(e7_xlsx, "j.xlsx"))
      2.times { TechnicalTests::Notices.receipt(started) }
    end
    assert_equal 1, kinds.(started).count("test_receipt")
    r2_s1_decide!(@app, "eliminate")
    [@app, started].each { |a| TechnicalTests::Notices.gate_outcome(a.reload) }
    assert_equal 0, MailDelivery.where(kind: "gate_outcome").count, "gate outcome before close"
  end

  test "notices: gate outcome once per applicant after close; the email carries no score, threshold or ranking" do
    a = travel_to(@t0 + 1.hour) { r2_s1_decide!(@app, "pass"); r2_answer(@app) }
    r2_score!(a, [3, 4]) # 60.0 on a 60 line
    travel_to(@t0 + 2.hours) { Gates::Close.call(stage: @job.stages.find_by!(code: "S1")) }
    travel_to(@t0 + 3.hours) { TechnicalTests::Tick.call; TechnicalTests::Notices.gate_outcome(@app) }
    assert_equal 1, MailDelivery.where(job_application: @app, kind: "gate_outcome").count
    mails = ActionMailer::Base.deliveries.select { |m| m.to.include?(@app.candidate.email) }
    refute_empty mails
    mails.each do |mail|
      body = mail.text_part ? mail.text_part.body.to_s : mail.body.to_s
      assert_no_match(/\b60[.,]0\b|\bskor\b|\bambang\b|\bperingkat\b|\branking\b/i, body, "#{mail.subject}: #{body[0, 200]}")
      assert_no_match(/\bAI\b/, body, "#{mail.subject} mentions AI")
    end
  end

  test "DB: a late answer written past the service, a swapped or removed answer file, a second notice row are refused" do
    late, = travel_to(@t0) { r2_apply(@job, name: "DB Uji") }
    a = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: late) }
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(e7_xlsx), filename: "x.xlsx", identify: false)
    a.answer_file.attach(blob)
    error = refused_by_database do
      a.update_columns(answered_at: a.due_at + 121.seconds, answer_blob_id: blob.id, answer_kind: "xlsx", answer_sha256: "0" * 64,
                       answer_bytes: blob.byte_size, answer_scan_state: "scan_unavailable")
    end
    assert_match "test_attempts_answer_in_time", error.message
    answered = travel_to(@t0 + 1.hour) { r2_answer(@app) }
    other = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(e7_xlsx([["lain"]])), filename: "y.xlsx", identify: false)
    att = answered.answer_file.attachment
    assert_match "never changes", e7_sql_error("UPDATE active_storage_attachments SET blob_id = #{other.id} WHERE id = #{att.id}")&.message.to_s
    assert_match "never changes", e7_sql_error("DELETE FROM active_storage_attachments WHERE id = #{att.id}")&.message.to_s
    MailDelivery.where(job_application: @app, kind: "test_receipt").delete_all
    MailDelivery.create!(job_application: @app, kind: "test_receipt", status: "sent")
    refused_by_database { MailDelivery.create!(job_application: @app, kind: "test_receipt", status: "failed", error_class: "X", error_message: "x") }
  end

  # ---- slice 5: scoring -------------------------------------------------------------------------
  test "rubric score hand-computed on weights 60/40 and the D9 boundary on the S2 threshold 60" do
    cases = { [4, 2] => [55.0, "eliminate"], [3, 4] => [60.0, "pass"], [3, 3] => [50.0, "eliminate"], [5, 1] => [60.0, "pass"],
              [1, 5] => [40.0, "eliminate"], [5, 5] => [100.0, "pass"], [1, 1] => [0.0, "eliminate"] }
    assert_equal 60, @job.stages.find_by!(code: "S2").threshold.to_i
    cases.each do |ratings, (score, outcome)|
      app, = travel_to(@t0) { r2_apply(@job, name: "Skor Uji") }
      attempt = travel_to(@t0 + 1.hour) { r2_s1_decide!(app, "pass"); r2_answer(app) }
      r2_score!(attempt, ratings)
      s2 = r2_s2(app)
      assert_equal score, s2.current_score.to_f, ratings.inspect
      assert_equal outcome, s2.current_decision.outcome, ratings.inspect
    end
  end

  test "scoring refused: consultant, HR PIC, owner, admin; a reviewer who is the job's consultant; a second reviewer; blank note; bad ratings" do
    attempt = travel_to(@t0 + 1.hour) { r2_answer(@app) }
    %w[consultant hr_pic owner admin].each do |role|
      assert_raises(TechnicalTests::ScoreAnswer::Refused, role) { r2_score!(attempt, [5, 5], reviewer: staff_user(role)) }
    end
    conflicted = r2_reviewer(email: "reviewer-konsultan@uji.example")
    @job.update_columns(consultant_id: conflicted.id)
    assert_raises(TechnicalTests::ScoreAnswer::Refused) { r2_score!(attempt.reload, [5, 5], reviewer: conflicted) }
    @job.update_columns(consultant_id: staff_user("consultant").id)
    attempt.reload
    ["", "   ", nil].each { |n| assert_raises(TechnicalTests::ScoreAnswer::Refused) { r2_score!(attempt, [5, 5], note: n) } }
    [[0, 5], [6, 5], ["4.5", 5], [5, nil], ["", 5]].each do |bad|
      assert_raises(TechnicalTests::ScoreAnswer::Refused, bad.inspect) { r2_score!(attempt, bad) }
    end
    assert_equal 0, r2_s2(@app).score_entries.count
    r2_score!(attempt, [5, 5])
    assert_raises(TechnicalTests::ScoreAnswer::Refused) { r2_score!(attempt, [1, 1], reviewer: r2_reviewer(email: "reviewer-dua@uji.example")) }
    assert_equal [100.0], r2_s2(@app).score_entries.pluck(:value).map(&:to_f)
  end

  test "DB: a score or review by the consultant (or a reviewer who is the job's consultant) on an answered test is refused" do
    attempt = travel_to(@t0 + 1.hour) { r2_answer(@app) }
    s2 = r2_s2(@app)
    [staff_user("consultant"), staff_user("hr_pic")].each do |u|
      assert_match "scored by a reviewer", refused_by_database {
        ScoreEntry.create!(participation: s2, value: 90, entered_by_id: u.id, event_at: Time.current, entered_at: Time.current)
      }.message
    end
    conflicted = r2_reviewer(email: "reviewer-konsultan2@uji.example")
    @job.update_columns(consultant_id: conflicted.id)
    refused_by_database { ScoreEntry.create!(participation: s2, value: 90, entered_by_id: conflicted.id, event_at: Time.current, entered_at: Time.current) }
    assert_match "is not a reviewer", e7_sql_error(<<~SQL)&.message.to_s
      INSERT INTO test_reviews (participation_id, test_attempt_id, reviewer_id, score_entry_id, decision_id, ratings, note, created_at)
      VALUES (#{s2.id}, #{attempt.id}, #{staff_user('consultant').id}, 0, 0, '{}', 'x', now())
    SQL
  end

  test "scoring an S1-eliminated candidate, on a closed gate or before an answer is refused" do
    unanswered, = travel_to(@t0) { r2_apply(@job, name: "Kosong Uji") }
    u = travel_to(@t0 + 1.hour) { TechnicalTests::Start.call(application: unanswered) }
    assert_raises(TechnicalTests::ScoreAnswer::Refused) { r2_score!(u, [5, 5]) }
    attempt = travel_to(@t0 + 1.hour) { r2_answer(@app) }
    r2_s1_decide!(@app, "eliminate")
    assert_raises(TechnicalTests::ScoreAnswer::Refused) { r2_score!(attempt, [5, 5]) }
    assert_equal 0, r2_s2(@app).score_entries.count
  end
end
