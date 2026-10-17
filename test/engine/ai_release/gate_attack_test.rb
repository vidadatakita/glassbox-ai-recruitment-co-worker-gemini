require "test_helper"
require_relative "ai_release_engine_support"

# Feature 09 test engine, run 1 (2026-10-10): the release gate (D51 B) attacked at the service and
# database layers. The property that costs money: no candidate text reaches the Gemini API unless a
# named reviewer released exactly those bytes. FakeGemini counts every HTTP request the real gem
# would have made.
class EngineAiReleaseBypassTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  test "no path sends a held text: jobs re-run, Mulai screening, calibration judging, consultant paste" do
    participation, fake, release = hold!(@job)
    assert_equal "awaiting_release", participation.screening_state
    assert release&.pending?, "control: a version waits"
    with_ai(fake) do
      3.times { ScreenParticipationJob.perform_now(participation.id) }
      Screening::Start.call(@job)
      drain_jobs!(release: false)
      Screening::JudgeCalibration.call(participation:, user: @job.consultant, outcome: "pass")
      drain_jobs!(release: false)
    end
    assert_equal 0, fake.requests.size, "a held text was sent without a release"

    # A consultant pastes text for a CV without an evidence section: prepared, held, not sent.
    p2, fake2, = hold!(@job, "Saya pekerja keras dan jujur.", name: "Calon Tempel")
    assert_equal "no_evidence_section", p2.screening_failure
    with_ai(fake2) do
      Screening::PasteCvText.call(participation: p2, user: @job.consultant, text: EVIDENCE_CV)
      drain_jobs!(release: false)
    end
    assert_equal ["awaiting_release", 0], [p2.reload.screening_state, fake2.requests.size]
  end

  test "retries reuse the released bytes; a consumed release is never reused after the rubric changes" do
    participation, fake, release = hold!(@job)
    fake.push(*Array.new(4) { gemini_error(503, "overloaded_error") }, gemini_message(criteria_for(@job)))
    with_ai(fake) do
      release!(release)
      drain_jobs!(release: false)
      assert_equal "screening_failed", participation.reload.screening_state
      Screening::Start.call(@job) # retry the SAME released text
      drain_jobs!(release: false)
    end
    assert_equal 5, fake.requests.size
    assert_equal [release.payload_text], sent_contents(fake).uniq, "every attempt sent exactly the released bytes"
    assert_equal "done", participation.reload.screening_state
    assert_equal release.id, participation.screening_results.sole.ai_release_id

    @job.requirements.where(tier: "nilai_tambah").first.update!(text: "Memiliki SIM A")
    with_ai(fake) do
      Screening::Start.call(@job)
      drain_jobs!(release: false)
    end
    assert_equal 5, fake.requests.size, "a changed rubric was sent on the old release"
    assert_equal "awaiting_release", participation.reload.screening_state
    refute_equal release.id, AiRelease.latest_for(participation).id
  end

  test "a released text not yet sent is never sent after the rubric changed; a new version waits" do
    participation, fake, release = hold!(@job)
    fake.push(*Array.new(4) { gemini_error(503, "overloaded_error") })
    with_ai(fake) do
      release!(release)
      drain_jobs!(release: false)
    end
    assert_equal [4, "screening_failed"], [fake.requests.size, participation.reload.screening_state], "control: released, failed, not consumed"
    @job.requirements.where(tier: "nilai_tambah").first.update!(text: "Memiliki SIM A")
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      Screening::Start.call(@job)
      drain_jobs!(release: false)
    end
    assert_equal 4, fake.requests.size, "the old release was sent with a changed rubric"
    assert_equal "awaiting_release", participation.reload.screening_state
  end

  # D51 B: "before every AI call (CV …) a named person reviews the redacted text". The client's
  # two non-release entry points check only the CV argument (#judge, #count_tokens) or only a digest
  # the caller computes itself (#judge_released), so any code that calls the client directly can
  # send candidate text without a release.
  test "a direct GeminiClient call cannot carry candidate text without a release" do
    candidate = "Rina Pratiwi, lahir 12-03-1995, Admin Gudang di PT Logistik Makmur"
    fake = FakeGemini.new(gemini_message([]), { totalTokens: 10 }, gemini_message([]))
    sent = []
    with_ai(fake) do
      client = Screening::GeminiClient.new
      attempts = {
        "judge with the sample CV and candidate text in the rubric" => -> { client.judge(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: [{ "id" => "R1", "tier" => "wajib", "requirement" => candidate, "cv_evidence" => "" }]) },
        "count_tokens with candidate text in the rubric" => -> { client.count_tokens(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: [{ "id" => "R1", "requirement" => candidate }]) },
        "judge_released with a self-computed digest" => -> { client.judge_released(payload: candidate, sha256: AiRelease.digest(candidate)) }
      }
      attempts.each do |label, call|
        before = fake.requests.size
        begin
          call.call
        rescue Screening::Errors::Unreleased, Screening::Errors::ReleaseMismatch, Screening::Errors::Base
          nil
        end
        sent << label if fake.requests.size > before && fake.bodies.last.include?("12-03-1995")
      end
    end
    assert_empty sent, "candidate text left through the client without a release: #{sent.inspect}"
  end

  test "control: the client refuses a non-sample CV and a digest that does not match" do
    fake = FakeGemini.new
    with_ai(fake) do
      client = Screening::GeminiClient.new
      assert_raises(Screening::Errors::Unreleased) { client.judge(redacted_cv: "CV lain", rubric_payload: []) }
      assert_raises(Screening::Errors::Unreleased) { client.count_tokens(redacted_cv: "CV lain", rubric_payload: []) }
      assert_raises(Screening::Errors::ReleaseMismatch) { client.judge_released(payload: "teks", sha256: AiRelease.digest("teks lain")) }
    end
    assert_equal 0, fake.requests.size
  end
end

class EngineAiReleaseDigestTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  # The append-only trigger is switched off INSIDE this test's transaction only (rolled back with
  # it) to simulate a stored text changed after the release (a tampered or corrupted row).
  def tamper!(release, new_text)
    conn = ActiveRecord::Base.connection
    conn.execute("ALTER TABLE ai_releases DISABLE TRIGGER ai_releases_append_only")
    conn.execute(ActiveRecord::Base.sanitize_sql_array(
      ["UPDATE ai_releases SET payload_text = ?, payload_sha256 = encode(sha256(convert_to(?, 'UTF8')), 'hex') WHERE id = ?", new_text, new_text, release.id]
    ))
  ensure
    conn.execute("ALTER TABLE ai_releases ENABLE TRIGGER ai_releases_append_only")
  end

  test "a text changed after its release is never sent; a new version goes back to the reviewer" do
    participation, fake, release = hold!(@job)
    with_ai(fake) do
      release!(release)
      # A change no residual check can see (so only the digest check stops it).
      tamper!(release, release.payload_text.sub("Admin Gudang", "Kepala Gudang"))
      fake.push(gemini_message(criteria_for(@job)))
      drain_jobs!(release: false)
    end
    assert_equal 0, fake.requests.size, "the changed text was sent"
    assert_equal ["release_mismatch"], participation.screening_attempts.where(error_kind: "release_mismatch").pluck(:error_kind).uniq
    assert_includes participation.screening_attempts.pluck(:error_kind), "release_mismatch"
    assert_equal "awaiting_release", participation.reload.screening_state
    refute_equal release.id, AiRelease.latest_for(participation).id
  end

  test "a digest mismatch between the gate and the client sends nothing" do
    participation, fake, release = hold!(@job)
    with_ai(fake) do
      release!(release)
      fake.push(gemini_message(criteria_for(@job)))
      original = Screening::GeminiClient.instance_method(:judge_released)
      Screening::GeminiClient.define_method(:judge_released) { |payload:, sha256:| original.bind_call(self, payload: payload + " ", sha256:) }
      begin
        drain_jobs!(release: false)
      ensure
        Screening::GeminiClient.define_method(:judge_released, original)
      end
    end
    assert_equal 0, fake.requests.size
    assert_equal 0, participation.reload.score_entries.count
  end
end

class EngineAiReleaseWhoTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  # Three roles (17 Oct 2026): Send to Gemini belongs to the hr_manager (old reviewer and owner);
  # the hr_admin (old consultant and HR PIC) is refused; the superadmin passes every role check.
  # The per-person rule (never the job's consultant) still binds everyone.
  test "only an hr_manager or superadmin who is not the job's consultant releases, cuts or declines (service and database)" do
    _, _, release = hold!(@job)
    with_ai(FakeGemini.new) do
      %w[consultant hr_pic].each do |role|
        user = staff_user(role)
        assert_raises(AiReleases::Refused, role) { release!(release, user:) }
        assert_raises(AiReleases::Refused, role) { AiReleases::Cut.call(release:, user:, line_numbers: [release.cv_line_start + 1]) }
        assert_raises(AiReleases::Refused, role) { AiReleases::Decline.call(release:, user:, note: "uji") }
        error = refused_by_database { raw_action!(release, user) }
        assert_includes error.message, "is not a reviewer or is the job's consultant", role
      end
      # Allowed side: the database accepts an hr_manager (owner) and the superadmin. Rolled back so
      # the release stays unreleased for the per-person checks below.
      %w[owner admin].each do |role|
        AiReleaseAction.transaction(requires_new: true) do
          raw_action!(release, staff_user(role))
          raise ActiveRecord::Rollback
        end
      end
      reviewer = staff_user("reviewer", email: "konsultan-reviewer@uji.example")
      @job.update!(consultant: reviewer)
      error = assert_raises(AiReleases::Refused) { release!(release, user: reviewer) }
      assert_equal "The reviewer cannot be the consultant of this vacancy.", error.message
      refused_by_database { raw_action!(release, reviewer) }
      cut_error = refused_by_database do
        AiRelease.insert!({ participation_id: release.participation_id, job_id: @job.id, payload_kind: "cv_screening",
                            payload_text: release.payload_text, payload_sha256: release.payload_sha256,
                            cv_line_start: release.cv_line_start, cv_line_end: release.cv_line_end,
                            rubric_digest: release.rubric_digest, source_sha256: release.source_sha256,
                            supersedes_id: release.id, cut_by_id: reviewer.id, cut_line_numbers: [release.cv_line_start + 1],
                            cut_sha256: AiRelease.digest("x"), created_at: Time.current })
      end
      assert_includes cut_error.message, "ai release cut refused", "the job's consultant cut a version at the database"
    end
    assert_equal 0, AiReleaseAction.count
  end

  test "an old version can never be released once a newer one exists (service and database)" do
    _, _, release = hold!(@job)
    newer = AiReleases::Cut.call(release:, user: releaser, line_numbers: [release.cv_line_start + 1])
    with_ai(FakeGemini.new) do
      assert_raises(AiReleases::Refused) { release!(release) }
      error = refused_by_database { raw_action!(release, releaser) }
      assert_includes error.message, "is not the latest"
      refused_by_database { raw_action!(newer, releaser, sha: release.payload_sha256) } # a digest of another version
      assert release!(newer), "control: the newest version releases"
    end
  end

  test "a version with residual findings is never released (service and database); after a cut it is" do
    cv = EVIDENCE_CV.sub("Mengelola stok", "Bekasi, 12-03-1995\nMengelola stok")
    _, fake, release = hold!(@job, cv)
    assert_includes release.residual_categories, "birth_date"
    with_ai(fake) do
      assert_raises(AiReleases::Refused) { release!(release) }
      error = refused_by_database { raw_action!(release, releaser) }
      assert_includes error.message, "residual-check findings"
      line = release.lines.index { |l| l.include?("12-03-1995") }
      cut = AiReleases::Cut.call(release:, user: releaser, line_numbers: [line])
      assert_empty cut.residual_categories
      release!(cut)
      fake.push(gemini_message(criteria_for(@job)))
      drain_jobs!(release: false)
    end
    assert_equal 1, fake.requests.size
    refute_includes fake.bodies.first, "12-03-1995"
  end
end

class EngineAiReleaseCutTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  test "a cut only replaces chosen CV lines with [REDACTED]; every other byte is unchanged" do
    _, _, release = hold!(@job)
    target = release.cv_line_start + 2
    cut = AiReleases::Cut.call(release:, user: releaser, line_numbers: [target.to_s, target, "x", nil])
    old_lines = release.lines
    new_lines = cut.lines
    assert_equal old_lines.size, new_lines.size
    changed = old_lines.each_index.reject { |i| old_lines[i] == new_lines[i] }
    assert_equal [target], changed
    assert_equal Screening::Redactor::MARK, new_lines[target]
    assert_equal [target], cut.cut_line_numbers
    assert_equal AiRelease.digest(old_lines[target]), cut.cut_sha256
  end

  test "a cut refuses requirement lines, out-of-range lines and an empty choice" do
    _, _, release = hold!(@job)
    [[0], [release.cv_line_start - 1], [release.cv_line_end + 1], [-1], [10_000], []].each do |numbers|
      assert_raises(AiReleases::Refused, numbers.inspect) { AiReleases::Cut.call(release:, user: releaser, line_numbers: numbers) }
    end
    assert_equal 1, AiRelease.where(participation_id: release.participation_id).count
  end

  # The database checks who cut and that the old version is undecided, but not WHAT changed: a
  # "cut" written directly can add text the reviewer never saw removed.
  test "the database refuses a superseding version that adds text instead of removing lines" do
    _, _, release = hold!(@job)
    added = release.payload_text.sub("Admin Gudang", "Admin Gudang (lahir 12-03-1995, beragama Konghucu)")
    refused_by_database do
      AiRelease.insert!({ participation_id: release.participation_id, job_id: @job.id, payload_kind: "cv_screening",
                          payload_text: added, payload_sha256: AiRelease.digest(added),
                          cv_line_start: release.cv_line_start, cv_line_end: release.cv_line_end,
                          rubric_digest: release.rubric_digest, source_sha256: release.source_sha256,
                          supersedes_id: release.id, cut_by_id: releaser.id, cut_line_numbers: [release.cv_line_start + 1],
                          cut_sha256: "x", created_at: Time.current })
    end
  end
end

class EngineAiReleaseEvidenceAndKeyTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  test "A keeps experience, education, skills, certifications, training; drops header, personal, hobby, family, references" do
    cv = <<~CV
      RINA PRATIWI
      Bekasi, 12-03-1995 · 0812-3456-7890
      PROFIL
      Ibu dua anak, aktif di pengajian
      PENGALAMAN KERJA
      2017 - 2024 Admin Gudang di PT Logistik Makmur
      DATA PRIBADI
      Agama Konghucu, status bujang
      PENDIDIKAN
      D3 Manajemen Logistik, lulus 2016
      HOBI
      Arisan keluarga besar Batak
      SERTIFIKASI
      Operator Forklift SIO
      KELUARGA
      Suami bekerja di Bekasi
      PELATIHAN
      Pelatihan K3 Umum 2019
      REFERENSI
      Bpk. Hendra, HRD PT Logistik Makmur
      KEAHLIAN
      Microsoft Excel tingkat lanjut
    CV
    _, _, release = hold!(@job, cv)
    kept = release.cv_part
    ["2017 - 2024 Admin Gudang di PT Logistik Makmur", "D3 Manajemen Logistik", "Operator Forklift SIO", "Pelatihan K3 Umum 2019",
     "Microsoft Excel tingkat lanjut"].each { |e| assert_includes kept, e }
    leaked = ["12-03-1995", "Ibu dua anak", "pengajian", "Konghucu", "bujang", "Arisan", "Batak", "Suami", "Hendra"].select { |v| kept.include?(v) }
    assert_empty leaked, "non-evidence content kept for sending: #{leaked.inspect}"
  end

  # Documented by the builder (record 09 §8 floating): content under an UNKNOWN heading after an
  # evidence section is kept and sent; the reviewer is the only check. Recorded, not a finding.
  test "note: content under an unknown heading after an evidence section is kept (the reviewer sees it)" do
    _, _, release = hold!(@job, "PENGALAMAN KERJA\nAdmin Gudang di PT Logistik Makmur, Cikarang\nKONTAK DARURAT\nIbu Siti Aminah (ibu kandung)\n")
    assert_includes release.cv_part, "Siti Aminah"
  end

  test "no key: the text is prepared and waits; release is refused; nothing is sent" do
    wire = FakeGemini.new
    Screening::AiClient.http_override = wire
    participation = Screening::Config.stub(:api_key, nil) do
      p = apply_with_cv!(@job)
      p.job_application.update!(cv_text: EVIDENCE_CV, cv_text_source: "pdf", cv_text_at: Time.current)
      drain_jobs!
      p.reload
    end
    release = AiRelease.latest_for(participation)
    assert_equal "awaiting_release", participation.screening_state
    Screening::Config.stub(:api_key, nil) do
      error = assert_raises(AiReleases::Refused) { release!(release) }
      assert_includes error.message, "No credentials are configured"
    end
    assert_equal [0, 0], [wire.requests.size, AiReleaseAction.count]
  ensure
    Screening::AiClient.http_override = nil
  end
end

class EngineAiReleaseRecordsTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  test "ai_releases and ai_release_actions refuse UPDATE, DELETE and TRUNCATE" do
    _, _, release = hold!(@job)
    release!(release) rescue nil # key may be off: an action row is made below if needed
    with_ai(FakeGemini.new) { release!(release) unless release.reload.released? }
    conn = ActiveRecord::Base.connection
    %w[ai_releases ai_release_actions].each do |table|
      e1 = refused_by_database { conn.execute("UPDATE #{table} SET created_at = created_at") }
      assert_includes e1.message, "#{table} is append-only: UPDATE refused"
      e2 = refused_by_database { conn.execute("DELETE FROM #{table}") }
      assert_match(/append-only: DELETE refused|foreign key/, e2.message)
    end
    e3 = refused_by_database { conn.execute("TRUNCATE ai_releases, ai_release_actions CASCADE") }
    assert_match(/append-only: TRUNCATE refused/, e3.message)
  end

  # Pilot measure (D51 C) tie-out: every figure equals an independent count of the rows.
  test "pilot measure figures tie out to the rows, per job and globally" do
    fake = FakeGemini.new
    a, = hold!(@job, EVIDENCE_CV, name: "Calon Satu", fake:)
    b, = hold!(@job, EVIDENCE_CV.sub("Mengelola stok", "Bekasi, 12-03-1995\nMengelola stok"), name: "Calon Dua", fake:)
    c, = hold!(@job, EVIDENCE_CV, name: "Calon Tiga", fake:)
    d, = hold!(@job, EVIDENCE_CV, name: "Calon Empat", fake:)
    other_job = screening_job
    e, = hold!(other_job, EVIDENCE_CV, name: "Calon Lima", fake:)
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)), gemini_message(criteria_for(@job), protected: ["religion"]), gemini_message(criteria_for(other_job)))
      release!(AiRelease.latest_for(a))
      rb = AiRelease.latest_for(b)
      cut = AiReleases::Cut.call(release: rb, user: releaser, line_numbers: [rb.lines.index { |l| l.include?("12-03-1995") }])
      cut = AiReleases::Cut.call(release: cut, user: releaser, line_numbers: [cut.cv_line_start + 1]) # a second cut of the same CV
      release!(cut)
      AiReleases::Decline.call(release: AiRelease.latest_for(c), user: releaser, note: "CV meragukan")
      release!(AiRelease.latest_for(e))
      drain_jobs!(release: false)
    end
    m = AiReleases::PilotMeasure.new(job: @job)
    expected = { cvs: 4, released: 2, declined: 1, cut: 1, residual: 1, answered: 2, model_flagged: 1 }
    assert_equal expected, expected.keys.to_h { |k| [k, m.public_send(k)] }, "hand-counted figures for the job"
    assert_equal 4, AiRelease.cv_screening.where(job_id: @job.id).distinct.count(:participation_id)
    g = AiReleases::PilotMeasure.new
    assert_equal [5, 3, 3], [g.cvs, g.released, g.answered]
    assert_nil m.per_100(1, m.cvs), "no rate below 100 CVs"
    assert_equal "awaiting_release", d.reload.screening_state
  end

  # Open item 4 (record 09 §8): the release texts are personal data (redacted evidence sections;
  # a version with residual findings, and every version before a cut, still holds the value the
  # reviewer removed). UU PDP (Pasal 8 hak penghapusan; consent withdrawal, Pasal 9/40), D16 and the
  # retention period (D32) require that they can be erased.
  #
  # Rewritten 2026-10-10 19:4x (superseded by run-2 F09-05/06): run 1 erased with a bare
  # update_all, which the database must now refuse (an erasure needs the orchestrator's erasure row
  # first; a digest change is refused). The property is unchanged: at consent withdrawal every
  # release text of the candidate, including the pre-cut version, is erasable, and is erased by the
  # one supported path, CandidateErasure.
  test "release texts can be erased when consent is withdrawn or the retention period ends" do
    cv = EVIDENCE_CV.sub("Mengelola stok", "Bekasi, 12-03-1995\nMengelola stok")
    participation, _, release = hold!(@job, cv)
    cut = AiReleases::Cut.call(release:, user: releaser, line_numbers: [release.lines.index { |l| l.include?("12-03-1995") }])
    assert_includes release.reload.payload_text, "12-03-1995", "control: the pre-cut version keeps the removed value"
    application = participation.job_application
    application.update_columns(consent_withdrawn_at: Time.current, status: "withdrawn")
    CandidateErasure.call(application: application.reload, reason: "consent_withdrawn")
    left = AiRelease.where(participation_id: participation.id).where.not(payload_text: nil).count
    assert_equal 0, left, "#{left} release texts still stored after consent withdrawal"
    assert_equal 2, AiReleaseErasure.where(ai_release_id: [release.id, cut.id]).count
  end
end
