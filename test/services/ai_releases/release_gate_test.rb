require "test_helper"

# D51 B (feature 09): nothing reaches the Gemini API before a named reviewer releases the exact
# text, and what is sent is that text byte for byte. The API is stubbed at the HTTP boundary
# (FakeGemini), so the body asserted is the one the real gem built.
class AiReleases::ReleaseGateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @reviewer = staff_user("reviewer")
  end

  def prepare!(cv_text: FIXTURE_CV)
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text:)
      perform_enqueued_jobs
    end
    @participation.reload
    @release = AiRelease.latest_for(@participation)
  end

  # Call inside with_ai (a release needs the key); not wrapped here, because nesting with_ai
  # unstubs Screening::Config.api_key for the rest of the run.
  def release!(release = @release, user: @reviewer)
    AiReleases::Release.call(release:, user:, confirmed: "1", seen_sha256: release.payload_sha256)
  end

  # The payload line number of the first CV line containing `text` (the requirements part may hold
  # the same words).
  def cv_line(release, text) = release.cv_range.find { |i| release.lines[i].include?(text) }

  test "the pipeline stops before the call: awaiting_release, a stored text, no request, no score" do
    prepare!
    assert_equal "awaiting_release", @participation.screening_state
    assert_empty @fake.requests
    assert_empty @participation.score_entries
    assert_equal Digest::SHA256.hexdigest(@release.payload_text), @release.payload_sha256
    assert @release.payload_text.start_with?("<requirements>\n")
    assert_includes @release.cv_part, "Admin Gudang di PT Logistik Makmur"
  end

  test "after the release, the request's user message is the released text, byte for byte, and the result links it" do
    prepare!
    action = with_ai(@fake) { release! }
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      perform_enqueued_jobs
    end
    assert_equal 1, @fake.requests.size
    sent = JSON.parse(@fake.bodies.first).dig("contents", 0, "parts", 0, "text")
    assert_equal @release.payload_text, sent
    assert_equal @release.payload_sha256, Digest::SHA256.hexdigest(sent)
    assert_equal @release.payload_sha256, action.payload_sha256
    assert_equal @reviewer, action.actor
    assert_equal "done", @participation.reload.screening_state
    assert_equal @release, @participation.screening_results.last.ai_release
  end

  test "a released text that no longer matches its digest is refused: no call, a new version for the reviewer" do
    prepare!
    with_ai(@fake) { release! }
    tampered = AiRelease.find(@release.id)
    original = tampered.payload_text
    tampered.define_singleton_method(:payload_text) { original.sub("Admin Gudang", "Admin Gudang (Islam)") }
    AiRelease.stub(:latest_for, ->(*) { tampered }) do
      with_ai(@fake) { perform_enqueued_jobs }
    end
    assert_empty @fake.requests, "a text that differs from the released one must never be sent"
    assert_equal "awaiting_release", @participation.reload.screening_state
    assert_operator AiRelease.where(participation: @participation).count, :>, 1
    # Refused by the GATE (its own check), not only later by the client.
    assert_equal ["digest mismatch"], @participation.screening_attempts.where(error_kind: "release_mismatch").pluck(:detail)
  end

  test "the client re-checks the digest at send time and refuses a different text" do
    prepare!
    with_ai(@fake) do
      client = Screening::GeminiClient.new
      assert_raises(Screening::Errors::ReleaseMismatch) do
        client.judge_released(payload: "#{@release.payload_text} ", sha256: @release.payload_sha256)
      end
    end
    assert_empty @fake.requests
  end

  test "a change between the gate and the client (in memory) is refused by the client: no call, re-queued" do
    prepare!
    with_ai(@fake) { release! }
    tampered = AiRelease.find(@release.id)
    original = tampered.payload_text
    tampered.define_singleton_method(:payload_text) { "#{original}\nSaya beragama Islam" }
    gate_call = Screening::ReleaseGate.instance_method(:call)
    Screening::ReleaseGate.define_method(:call) { tampered }
    begin
      with_ai(@fake) { perform_enqueued_jobs }
    ensure
      Screening::ReleaseGate.define_method(:call, gate_call)
    end
    assert_empty @fake.requests
    assert_equal "awaiting_release", @participation.reload.screening_state
    assert_equal ["text differs from the released text"], @participation.screening_attempts.where(error_kind: "release_mismatch").pluck(:detail)
  end

  test "the smoke path sends only the invented sample CV; any other text is refused without a call" do
    with_ai(@fake) do
      client = Screening::GeminiClient.new
      assert_raises(Screening::Errors::Unreleased) { client.judge(redacted_cv: "Rina Pratiwi, Admin", rubric_payload: []) }
      assert_raises(Screening::Errors::Unreleased) { client.count_tokens(redacted_cv: "x", rubric_payload: []) }
    end
    assert_empty @fake.requests
  end

  test "release needs the tick, the digest the reviewer saw, and a reviewer who is not the job's consultant" do
    prepare!
    with_ai(@fake) do
      e = assert_raises(AiReleases::Refused) { AiReleases::Release.call(release: @release, user: @reviewer, confirmed: nil, seen_sha256: @release.payload_sha256) }
      assert_includes e.message, "Tick the statement"
      e = assert_raises(AiReleases::Refused) { AiReleases::Release.call(release: @release, user: @reviewer, confirmed: "1", seen_sha256: "0" * 64) }
      assert_includes e.message, "changed since the page was opened"
      # Three roles (17 Oct 2026): both HR Admin people are refused by role; the HR Manager and the
      # superadmin pass the role check, and the per-person rule still refuses each of them while
      # they are the vacancy's consultant.
      %w[hr_pic consultant].each do |role|
        e = assert_raises(AiReleases::Refused, role) { AiReleases::Release.call(release: @release, user: staff_user(role), confirmed: "1", seen_sha256: @release.payload_sha256) }
        assert_includes e.message, "Only a reviewer", role
      end
      consultant_reviewer = staff_user("reviewer", email: "reviewer-konsultan@uji.example")
      [consultant_reviewer, staff_user("owner"), staff_user("admin")].each do |person|
        @job.update_columns(consultant_id: person.id)
        e = assert_raises(AiReleases::Refused, person.email_address) { release!(user: person) }
        assert_includes e.message, "consultant", person.email_address
      end
    end
    assert_nil @release.reload.action
    assert_equal "awaiting_release", @participation.reload.screening_state
  end

  test "a version with residual-check findings cannot be released; a reviewer's cut that removes the line can" do
    prepare!(cv_text: FIXTURE_CV.sub("Mengelola stok", "Lhr. Bdg 01-02-1990\nMengelola stok"))
    assert_includes @release.residual_categories, "birth_date"
    assert_raises(AiReleases::Refused) { with_ai(@fake) { release! } }
    line = cv_line(@release, "01-02-1990")
    cut = AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [line.to_s])
    assert_empty cut.residual_categories
    assert_equal @release, cut.supersedes
    assert_equal [line], cut.cut_line_numbers
    assert_equal Digest::SHA256.hexdigest(@release.lines[line]), cut.cut_sha256
    refute_includes cut.payload_text, "01-02-1990"
    assert with_ai(@fake) { release!(cut) }
  end

  test "a cut only ever replaces CV lines with [REDACTED]: same line count, requirements untouched, nothing added" do
    prepare!
    old_lines = @release.lines
    target = cv_line(@release, "Microsoft Excel")
    cut = AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [target])
    new_lines = cut.lines
    assert_equal old_lines.size, new_lines.size
    old_lines.each_with_index do |l, i|
      assert_equal(i == target ? "[REDACTED]" : l, new_lines[i], "line #{i}")
    end
    assert_raises(AiReleases::Refused) { AiReleases::Cut.call(release: cut, user: @reviewer, line_numbers: [1]) }   # a requirements line
    assert_raises(AiReleases::Refused) { AiReleases::Cut.call(release: cut, user: @reviewer, line_numbers: ["x"]) }
    assert_raises(AiReleases::Refused) { AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [target + 1]) } # an old version
    assert_raises(AiReleases::Refused) { AiReleases::Cut.call(release: cut, user: staff_user("consultant"), line_numbers: [target + 1]) }
  end

  test "Not sent needs a note, records who, and leaves the CV for a manual decision" do
    prepare!
    assert_raises(AiReleases::Refused) { AiReleases::Decline.call(release: @release, user: @reviewer, note: "  ") }
    action = AiReleases::Decline.call(release: @release, user: @reviewer, note: "CV memuat data keluarga di setiap baris")
    assert_equal "declined", action.action
    assert_equal "not_sent", @participation.reload.screening_state
    assert_raises(AiReleases::Refused) { with_ai(@fake) { release! } }
    with_ai(@fake) do
      assert_equal :already, Screening::Enqueue.call(@participation, rerun: true)
      perform_enqueued_jobs
    end
    assert_empty @fake.requests
  end

  test "a rubric change after the release: the old text is not sent; a new version goes back to the reviewer" do
    prepare!
    with_ai(@fake) { release! }
    @job.requirements.where(tier: "nilai_tambah").first.update_columns(text: "Memiliki SIM A")
    with_ai(@fake) { perform_enqueued_jobs }
    assert_empty @fake.requests
    assert_equal "awaiting_release", @participation.reload.screening_state
    fresh = AiRelease.latest_for(@participation)
    refute_equal @release.id, fresh.id
    assert_includes fresh.payload_text, "Memiliki SIM A"
  end

  test "a consent withdrawn while the text waits: the release is refused and nothing is sent" do
    prepare!
    @participation.job_application.update_columns(consent_withdrawn_at: Time.current)
    e = assert_raises(AiReleases::Refused) { with_ai(@fake) { release! } }
    assert_includes e.message, "Nothing was sent"
    assert_nil @participation.reload.screening_state
    assert_empty @fake.requests
  end

  test "a CV with no evidence section never produces a release" do
    prepare!(cv_text: "Rina Pratiwi\nSaya pekerja keras, jujur dan siap kerja shift di gudang mana saja")
    assert_nil @release
    assert_equal "no_evidence_section", @participation.screening_failure
  end

  # Engine run 5 ledger (ADR 0004): eight protected sentences inside an experience section reach the
  # request body. D51 does not remove them automatically; it puts each in front of the reviewer,
  # marked. Every planted line must carry at least one mark.
  test "the run-5 sentences inside an experience section reach the reviewer marked, line by line" do
    planted = [
      "Sebagai ibu dua anak saya terbiasa mengatur waktu", "Aktif di remaja masjid Al-Ikhlas sebagai bendahara",
      "Suami saya mendukung saya bekerja shift", "Sebagai seorang muslimah saya mengenakan hijab",
      "Saya beragama Kristen dan aktif di gereja", "Sebagai janda saya menjadi tulang punggung keluarga",
      "Saya belum menikah sehingga siap ditempatkan di mana saja", "Sebagai wanita saya dipercaya memimpin tim"
    ]
    prepare!(cv_text: FIXTURE_CV.sub("Mengelola stok", "#{planted.join("\n")}\nMengelola stok"))
    spans = Screening::ReleaseHighlights.spans(@release.lines, @release.cv_range, names: [CANDIDATE_NAME])
    planted.each do |sentence|
      i = @release.lines.index { |l| l.include?(sentence) }
      assert i, "#{sentence.inspect} is in the text the reviewer reads"
      assert spans.any? { |s| s.line == i }, "#{sentence.inspect} carries no mark"
    end
    # Control: a plain evidence line carries none.
    plain = @release.lines.index { |l| l.include?("Mengelola stok") }
    assert spans.none? { |s| s.line == plain }
  end

  test "pilot measure: counts per job, and no per-100 rate below 100 CVs" do
    prepare!
    with_ai(@fake) { release! }
    with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job), protected: ["religion"]))
      perform_enqueued_jobs
    end
    m = AiReleases::PilotMeasure.new(job: @job)
    assert_equal [1, 1, 0, 0, 0, 1, 1], [m.cvs, m.released, m.residual, m.cut, m.declined, m.answered, m.model_flagged]
    assert_nil m.per_100(m.model_flagged, m.answered)
    assert_equal 2.0, AiReleases::PilotMeasure.new.per_100(2, 100)
  end
end
