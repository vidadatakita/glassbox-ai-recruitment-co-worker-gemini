require "test_helper"
require "rake"
require_relative "ai_release_engine_support"

# Feature 09 test engine, run 3 (2026-10-10 19:4x): CandidateErasure, the one entry point for
# consent withdrawal (Pasal 40), missing consent (D16) and retention end (D32, §4.2).
class EngineAiReleaseRun3ErasureTest < ActiveSupport::TestCase
  include AiReleaseEngineSupport

  UNIQUE = "Mengelola stok 4.321 SKU gudang dingin vaksin".freeze

  setup { @job = screening_job }

  # A candidate with every kind of stored text: release versions (with a cut), a result whose quote
  # is CV text, a stage recommendation and a stage note, the extracted CV text and the CV file.
  def full_candidate!(name: CANDIDATE_NAME)
    cv = EVIDENCE_CV.sub("Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan.", "#{UNIQUE}\nBekasi, 12-03-1995")
    participation, fake, release = hold!(@job, cv, name:)
    cut = AiReleases::Cut.call(release:, user: releaser, line_numbers: [release.lines.index { |l| l.include?("12-03-1995") }])
    key = Screening::Rubric.for(@job).criteria.find { |c| c.tier == "sebaiknya" }.key
    with_ai(fake) do
      fake.push(gemini_message(criteria_with(@job, { key => { judgement: "3", quote: UNIQUE } })))
      release!(cut)
      drain_jobs!(release: false)
    end
    StageRecommendation.insert!({ participation_id: participation.id, requested_by_id: staff_user("hr_pic").id, status: "failed", summary: "Catatan: #{UNIQUE}", reasons: {}, prompt_version: "uji", created_at: Time.current })
    ProgressionChoice.insert!({ participation_id: participation.id, choice: "tidak_lanjut", direction: "tidak_lanjut", note: "Cerita: #{UNIQUE}", actor_id: staff_user("hr_pic").id, created_at: Time.current })
    participation.reload
  end

  def copies(participation)
    app = participation.job_application.reload
    {
      "ai_releases" => AiRelease.where(participation_id: participation.id).where.not(payload_text: nil).count,
      "screening_results quotes" => ScreeningResult.where(participation_id: participation.id).where("judgements::text LIKE ?", "%4.321 SKU%").count,
      "stage_recommendations" => StageRecommendation.where(participation_id: participation.id).where("summary LIKE ?", "%4.321%").count,
      "stage_notes" => ProgressionChoice.where(participation_id: participation.id).where("note LIKE ?", "%4.321%").count,
      "cv_text" => app.cv_text.present? ? 1 : 0,
      "cv file" => app.cv.attached? ? 1 : 0
    }
  end

  test "withdraw_consent! leaves no copy of the CV text, and the CV file is purged" do
    participation = full_candidate!
    assert(copies(participation).values.all?(&:positive?), "control: every copy exists before: #{copies(participation)}")
    Portal::CandidateActions.new(participation.job_application.reload).withdraw_consent!
    left = copies(participation).select { |_, n| n.positive? }
    assert_empty left, "copies left after consent withdrawal: #{left.inspect}"
  end

  test "scores, decisions, digests and release decisions are kept; quotes only are removed from judgements" do
    participation = full_candidate!
    result = participation.screening_results.sole
    before = { score: result.score, entry: participation.score_entries.sole.value, sha: AiRelease.where(participation_id: participation.id).order(:id).pluck(:payload_sha256),
               actions: AiReleaseAction.joins(:ai_release).where(ai_releases: { participation_id: participation.id }).count,
               judged: result.criteria.map { |c| [c["key"], c["judgement"], c["verified"]] } }
    CandidateErasure.call(application: participation.job_application, reason: "retention_expired", actor: staff_user("admin"))
    result.reload
    after = { score: result.score, entry: participation.score_entries.sole.value, sha: AiRelease.where(participation_id: participation.id).order(:id).pluck(:payload_sha256),
              actions: AiReleaseAction.joins(:ai_release).where(ai_releases: { participation_id: participation.id }).count,
              judged: result.criteria.map { |c| [c["key"], c["judgement"], c["verified"]] } }
    assert_equal before, after
    assert(result.criteria.all? { |c| c["quote"].nil? })
  end

  test "idempotent: a second call erases nothing and writes no second erasure record" do
    participation = full_candidate!
    app = participation.job_application
    CandidateErasure.call(application: app, reason: "retention_expired")
    rows = [AiReleaseErasure.count, ScreeningResultErasure.count, StageTextErasure.count]
    second = CandidateErasure.call(application: app.reload, reason: "retention_expired")
    assert_equal({ releases: 0, results: 0, stage_texts: 0, cv_text: 0, cv_file: 0 }, second)
    assert_equal rows, [AiReleaseErasure.count, ScreeningResultErasure.count, StageTextErasure.count]
  end

  test "rollback: when any part fails, nothing is erased and the withdrawal itself is undone" do
    participation = full_candidate!
    app = participation.job_application
    StageTextErasure.stub(:create!, ->(**) { raise ActiveRecord::StatementInvalid, "simulated refusal" }) do
      assert_raises(ActiveRecord::StatementInvalid) { Portal::CandidateActions.new(app.reload).withdraw_consent! }
    end
    left = copies(participation)
    assert(left.values.all?(&:positive?), "a part was erased although the erasure failed: #{left.inspect}")
    assert_nil app.reload.consent_withdrawn_at, "the withdrawal was kept although its erasure failed"
    assert_equal 0, AiReleaseErasure.count + ScreeningResultErasure.count + StageTextErasure.count
  end

  test "rollback of CandidateErasure on its own: a failing part erases nothing (its own transaction)" do
    participation = full_candidate!
    StageTextErasure.stub(:create!, ->(**) { raise ActiveRecord::StatementInvalid, "simulated refusal" }) do
      assert_raises(ActiveRecord::StatementInvalid) do
        CandidateErasure.call(application: participation.job_application, reason: "retention_expired")
      end
    end
    left = copies(participation)
    assert(left.values.all?(&:positive?), "a part was erased although the erasure failed: #{left.inspect}")
  end

  test "no erasure without the orchestrator's record, even with consent withdrawn" do
    participation = full_candidate!
    participation.job_application.update_columns(consent_withdrawn_at: Time.current, status: "withdrawn")
    refused = {
      "ai_releases" => -> { AiRelease.where(participation_id: participation.id).update_all(payload_text: nil) },
      "screening_results" => -> { ScreeningResult.where(participation_id: participation.id).update_all(narratives: nil) },
      "stage_recommendations" => -> { StageRecommendation.where(participation_id: participation.id).update_all(summary: nil) },
      "stage_notes" => -> { ProgressionChoice.where(participation_id: participation.id).update_all(note: nil) }
    }.reject do |_, statement|
      ActiveRecord::Base.transaction(requires_new: true) { statement.call }
      false
    rescue ActiveRecord::StatementInvalid
      true
    end.keys
    assert_empty refused, "erased by a bare UPDATE without an erasure record: #{refused.inspect}"
  end

  test "a pending release erased at retention end can never be released or sent" do
    participation, fake, release = hold!(@job)
    CandidateErasure.call(application: participation.job_application, reason: "retention_expired")
    with_ai(fake) do
      assert_raises(AiReleases::Refused, ActiveRecord::StatementInvalid) { release!(release.reload) }
      fake.push(gemini_message(criteria_for(@job)))
      Screening::Start.call(@job)
      drain_jobs!
    end
    assert_equal 0, fake.requests.size
  end

  test "the rake task erases expired, withdrawn and no-consent applications only, and prints counts only" do
    expired = full_candidate!(name: "Calon Kedaluwarsa")
    current = full_candidate!(name: "Calon Masih Berlaku")
    expired.job_application.update_columns(consent_at: 400.days.ago, consent_retention_days: 365)
    current.job_application.update_columns(consent_at: 10.days.ago, consent_retention_days: 365)
    Rails.application.load_tasks unless Rake::Task.task_defined?("glassbox:retention:erase_expired")
    task = Rake::Task["glassbox:retention:erase_expired"]
    task.reenable
    out, = capture_io { task.invoke }
    assert_empty(copies(expired).select { |_, n| n.positive? }, "the expired application was not erased")
    assert(copies(current).except("cv file").values.all?(&:positive?), "an application inside its retention period was erased")
    refute_match(/Calon|4\.321|12-03-1995/, out, "the rake output prints candidate data")
    assert_match(/retention_expired 1/, out)
  end
end
