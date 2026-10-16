require "test_helper"
require_relative "ai_release_engine_support"

# Feature 09 test engine, run 2 (2026-10-10, after F09-01..03 fixes: AiClient#send_released,
# AiReleases::Erase, ai_release_erasures, migrations 20261010221000/221500). Run-1 files unchanged.
class EngineAiReleaseRun2ClientTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  # Deviation 1: S1 still calls judge_released(payload:, sha256:), and the client looks the release
  # up BY DIGEST. Two candidates whose evidence text is identical share a digest by design.
  test "two candidates with identical released texts: each result is linked to its own release, each release used once" do
    fake = FakeGemini.new
    a, _, ra = hold!(@job, EVIDENCE_CV, name: "Calon Kembar Satu", fake:)
    b, _, rb = hold!(@job, EVIDENCE_CV, name: "Calon Kembar Dua", fake:)
    assert_equal ra.payload_sha256, rb.payload_sha256, "control: identical texts, identical digests"
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)), gemini_message(criteria_for(@job)))
      release!(rb)
      release!(ra)
      drain_jobs!(release: false)
    end
    assert_equal 2, fake.requests.size
    assert_equal [rb.id, ra.id].sort, [b.reload.screening_results.sole.ai_release_id, a.reload.screening_results.sole.ai_release_id].sort
    assert_equal rb.id, b.screening_results.sole.ai_release_id
    assert_equal ra.id, a.screening_results.sole.ai_release_id
  end

  test "a consumed release replayed through the client is refused when no other unused release has its bytes" do
    participation, fake, release = hold!(@job)
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      release!(release)
      drain_jobs!(release: false)
      assert_equal 1, fake.requests.size
      assert_raises(Screening::Errors::Unreleased) do
        Screening::GeminiClient.new.judge_released(payload: release.payload_text, sha256: release.payload_sha256)
      end
      assert_raises(Screening::Errors::Unreleased) { Screening::GeminiClient.new.send_released(release.id) }
    end
    assert_equal 1, fake.requests.size
    assert_equal "done", participation.reload.screening_state
  end

  test "a release erased after the gate found it and before the client sends: nothing is sent, nothing stored" do
    participation, fake, release = hold!(@job)
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      release!(release)
      original = Screening::GeminiClient.instance_method(:send_released)
      Screening::GeminiClient.define_method(:send_released) do |id|
        app = participation.job_application
        app.update_columns(consent_withdrawn_at: Time.current, status: "withdrawn")
        AiReleases::Erase.call(application: app, reason: "consent_withdrawn")
        original.bind_call(self, id)
      end
      begin
        drain_jobs!(release: false)
      rescue StandardError
        nil # the re-raised error of the job is expected here; the assertions below are the test
      ensure
        Screening::GeminiClient.define_method(:send_released, original)
      end
    end
    assert_equal 0, fake.requests.size, "an erased release was sent"
    assert_equal 0, participation.reload.screening_results.count
    assert_nil release.reload.payload_text
  end

  test "consent withdrawn while the request is in flight: the bytes left, but no result is stored and the text is erased" do
    hook = Class.new(FakeGemini) do
      attr_accessor :before
      def call(uri, headers, body)
        before&.call
        super
      end
    end
    participation, _, release = hold!(@job)
    fake = hook.new(gemini_message(criteria_for(@job)))
    with_ai(fake) do
      release!(release)
      fake.before = -> { Portal::CandidateActions.new(participation.job_application.reload).withdraw_consent! }
      drain_jobs!(release: false)
    end
    assert_equal 1, fake.requests.size, "control: the request was in flight"
    assert_equal [0, nil], [participation.reload.screening_results.count, release.reload.payload_text]
  end
end

class EngineAiReleaseRun2EraseTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  setup { @job = screening_job }

  def withdraw!(participation) = participation.job_application.update_columns(consent_withdrawn_at: Time.current, status: "withdrawn")

  test "Erase (retention end): text gone, erasure row per version with actor and reason, digest and decisions kept" do
    _, _, release = hold!(@job)
    cut = AiReleases::Cut.call(release:, user: releaser, line_numbers: [release.cv_line_start + 1])
    admin = staff_user("admin")
    count = AiReleases::Erase.call(application: release.participation.job_application, reason: "retention_expired", actor: admin)
    assert_equal 2, count
    [release, cut].each do |r|
      r.reload
      assert_nil r.payload_text
      assert_equal 64, r.payload_sha256.length, "the digest stays for the audit trail"
      erasure = AiReleaseErasure.find_by!(ai_release_id: r.id)
      assert_equal ["retention_expired", admin.id], [erasure.reason, erasure.actor_id]
    end
    assert_equal [release.cv_line_start + 1], cut.cut_line_numbers
  end

  test "without withdrawn consent or an erasure row, the database refuses to erase (control)" do
    _, _, release = hold!(@job)
    error = refused_by_database { AiRelease.where(id: release.id).update_all(payload_text: nil) }
    assert_includes error.message, "needs an ai_release_erasures row"
    refused_by_database { AiRelease.where(id: release.id).update_all(payload_text: "teks lain") }
  end

  # Deviation 2: for a withdrawn candidate the trigger accepts an UPDATE that also changes the
  # digest, and silently keeps the old digest. An append-only audit table should refuse a write
  # it will not perform (D63's retention_blankings trigger refuses any change beyond NULLing).
  test "an UPDATE that tries to change the digest while erasing is refused, not silently rewritten" do
    participation, _, release = hold!(@job)
    withdraw!(participation)
    old_sha = release.payload_sha256
    refused = begin
      ActiveRecord::Base.transaction(requires_new: true) do
        AiRelease.where(id: release.id).update_all(payload_text: nil, payload_sha256: "0" * 64)
      end
      false
    rescue ActiveRecord::StatementInvalid
      true
    end
    stored = AiRelease.where(id: release.id).pick(:payload_sha256)
    assert refused, "the UPDATE reported success; digest stored #{stored == old_sha ? 'unchanged (silently kept)' : 'CHANGED'}"
  end

  # Deviation 2b: an erasure by ANY statement (no service, no actor) for a withdrawn candidate is
  # legitimised by an auto-written record with actor NULL. D63 (retention_blankings) refuses an
  # UPDATE unless the blanking row was written first by the service.
  test "an erasure without a recorded erasure row is refused, the same shape as D63 retention_blankings" do
    participation, _, release = hold!(@job)
    withdraw!(participation)
    error = nil
    begin
      ActiveRecord::Base.transaction(requires_new: true) { AiRelease.where(id: release.id).update_all(payload_text: nil) }
    rescue ActiveRecord::StatementInvalid => e
      error = e
    end
    auto = AiReleaseErasure.find_by(ai_release_id: release.id)
    assert error, "erased by a bare UPDATE; the database wrote its own erasure row (actor #{auto&.actor_id.inspect}, note #{auto&.note.inspect})"
  end

  # Every copy of candidate text after withdraw_consent! (Pasal 40; D16 for the CV text).
  test "withdraw_consent! erases every stored copy of the candidate's CV text" do
    unique = "Mengelola stok 4.321 SKU gudang dingin vaksin"
    cv = EVIDENCE_CV.sub("Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan.", unique)
    participation, fake, release = hold!(@job, cv)
    keys = Screening::Rubric.for(@job).criteria.select { |c| c.tier == "sebaiknya" }.map(&:key)
    with_ai(fake) do
      fake.push(gemini_message(criteria_with(@job, { keys.first => { judgement: "3", quote: unique } })))
      release!(release)
      drain_jobs!(release: false)
    end
    assert_equal 1, participation.reload.screening_results.count, "control: a result with the quote was stored"
    StageRecommendation.insert!({ participation_id: participation.id, requested_by_id: staff_user("hr_pic").id, status: "failed", summary: "Catatan wawancara: #{unique}", reasons: {}, prompt_version: "uji", created_at: Time.current })
    ProgressionChoice.insert!({ participation_id: participation.id, choice: "tidak_lanjut", direction: "tidak_lanjut", note: "Kandidat bercerita: #{unique}", actor_id: staff_user("hr_pic").id, created_at: Time.current })
    Portal::CandidateActions.new(participation.job_application.reload).withdraw_consent!
    copies = {
      "ai_releases.payload_text" => AiRelease.where(participation_id: participation.id).where("payload_text LIKE ?", "%4.321 SKU%").count,
      "screening_results.judgements (quotes)" => ScreeningResult.where(participation_id: participation.id).where("judgements::text LIKE ?", "%4.321 SKU%").count,
      "stage_recommendations.summary" => StageRecommendation.where(participation_id: participation.id).where("summary LIKE ?", "%4.321 SKU%").count,
      "progression_choices.note" => ProgressionChoice.where(participation_id: participation.id).where("note LIKE ?", "%4.321 SKU%").count,
      "job_applications.cv_text" => JobApplication.where(id: participation.job_application_id).where("cv_text LIKE ?", "%4.321 SKU%").count
    }.select { |_, n| n.positive? }
    assert_empty copies, "candidate text still stored after consent withdrawal: #{copies.inspect}"
  end
end
