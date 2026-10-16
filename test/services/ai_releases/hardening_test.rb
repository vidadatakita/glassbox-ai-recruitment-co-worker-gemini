require "test_helper"
require "rake"

# Feature 09 after test engine run 1: F09-01 (the client is the boundary), F09-02 (a cut can only
# replace CV lines with [REDACTED], checked by the database), F09-03 (release texts are erasable,
# logged, at consent withdrawal, missing consent and retention end; nothing else may change).
class AiReleases::HardeningTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @reviewer = staff_user("reviewer")
    with_ai(@fake) do
      @participation = apply_with_cv!(@job)
      perform_enqueued_jobs
    end
    @release = AiRelease.latest_for(@participation)
  end

  def refused_by_db
    error = assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction(requires_new: true) { yield } }
    error
  end

  # --- F09-01 ---------------------------------------------------------------------------------

  test "the sample path refuses candidate text in the rubric; only the sample CV with the sample rubric passes" do
    with_ai(@fake) do
      client = Screening::GeminiClient.new
      rubric = [{ "id" => "R1", "tier" => "wajib", "requirement" => "Rina Pratiwi lahir 12-03-1995", "cv_evidence" => "" }]
      assert_raises(Screening::Errors::Unreleased) { client.judge(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: rubric) }
      assert_raises(Screening::Errors::Unreleased) { client.count_tokens(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: rubric) }
      @fake.push(gemini_message([]))
      client.judge(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: Screening::Sample.rubric.payload) # control
    end
    assert_equal 1, @fake.requests.size
    refute_includes @fake.bodies.first, "12-03-1995"
  end

  test "judge_released with a self-computed digest, an unreleased text, or a used release sends nothing" do
    text = "Rina Pratiwi, lahir 12-03-1995"
    with_ai(@fake) do
      client = Screening::GeminiClient.new
      assert_raises(Screening::Errors::Unreleased) { client.judge_released(payload: text, sha256: AiRelease.digest(text)) }
      assert_raises(Screening::Errors::Unreleased) { client.judge_released(payload: @release.payload_text, sha256: @release.payload_sha256) }
      assert_raises(Screening::Errors::Unreleased) { client.send_released(@release.id) }
      release_held!(reviewer: @reviewer)
      @fake.push(gemini_message(criteria_for(@job)))
      perform_enqueued_jobs
      assert_equal 1, @fake.requests.size, "control: the released text was sent once"
      assert_raises(Screening::Errors::Unreleased) { client.send_released(@release.id) }
      assert_raises(Screening::Errors::Unreleased) { client.judge_released(payload: @release.payload_text, sha256: @release.payload_sha256) }
    end
    assert_equal 1, @fake.requests.size
  end

  test "call_api refuses content that send_released or the sample path did not approve (a subclass cannot bypass)" do
    sneaky = Class.new(Screening::GeminiClient) { def push_text(text) = call_api(text) }
    with_ai(@fake) do
      assert_raises(Screening::Errors::Unreleased) { sneaky.new.push_text("Rina Pratiwi, lahir 12-03-1995") }
    end
    assert_empty @fake.requests
  end

  # --- F09-02 ---------------------------------------------------------------------------------

  def raw_cut(text, lines:)
    AiRelease.insert!({ participation_id: @release.participation_id, job_id: @job.id, payload_kind: "cv_screening",
                        payload_text: text, payload_sha256: AiRelease.digest(text), cv_line_start: @release.cv_line_start,
                        cv_line_end: @release.cv_line_end, rubric_digest: @release.rubric_digest,
                        source_sha256: @release.source_sha256, supersedes_id: @release.id, cut_by_id: @reviewer.id,
                        cut_line_numbers: lines, cut_sha256: "x", created_at: Time.current })
  end

  test "the database refuses a 'cut' that adds text, touches the requirements, or misstates its lines" do
    cv_line = @release.cv_range.find { |i| @release.lines[i].include?("Admin Gudang") }
    added = @release.lines.tap { |l| l[cv_line] = "#{l[cv_line]} (beragama Konghucu)" }.join("\n")
    refused_by_db { raw_cut(added, lines: [cv_line]) }
    req = @release.lines.tap { |l| l[1] = "[REDACTED]" }.join("\n")
    refused_by_db { raw_cut(req, lines: [1]) }
    marked = @release.lines.tap { |l| l[cv_line] = "[REDACTED]" }.join("\n")
    refused_by_db { raw_cut(marked, lines: [cv_line + 1]) }
    refused_by_db { raw_cut("#{marked}\nbaris baru", lines: [cv_line]) }
    raw_cut(marked, lines: [cv_line]) # control: a true cut is accepted
    assert_equal 2, AiRelease.where(participation: @participation).count
  end

  # --- F09-03 ---------------------------------------------------------------------------------

  test "consent withdrawal erases every release text in the same transaction; digest and records stay" do
    line = @release.cv_range.find { |i| @release.lines[i].include?("Microsoft Excel") }
    cut = AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [line])
    digests = [@release.payload_sha256, cut.payload_sha256]
    Portal::CandidateActions.new(@participation.job_application).withdraw_consent!
    rows = AiRelease.where(participation: @participation).order(:id)
    assert_equal [nil, nil], rows.map(&:payload_text)
    assert_equal digests, rows.map(&:payload_sha256)
    assert_equal %w[consent_withdrawn consent_withdrawn], AiReleaseErasure.where(ai_release_id: rows.map(&:id)).pluck(:reason)
    assert_equal @reviewer, rows.last.cut_by
  end

  # F09-05 / F09-06 (engine run 2): an erase needs a pre-recorded erasure row, whatever the consent
  # state, and any other change, including the digest, is refused (never silently kept).
  test "an erase needs an erasure row written first; no other column, not even the digest, may change" do
    e = refused_by_db { AiRelease.where(id: @release.id).update_all(payload_text: nil) }
    assert_includes e.message, "append-only: UPDATE refused"
    @participation.job_application.update_columns(consent_withdrawn_at: Time.current)
    refused_by_db { AiRelease.where(id: @release.id).update_all(payload_text: nil) }
    assert_nil AiReleaseErasure.find_by(ai_release_id: @release.id), "the database never writes the record itself"
    AiReleaseErasure.create!(ai_release: @release, reason: "consent_withdrawn", created_at: Time.current)
    refused_by_db { AiRelease.where(id: @release.id).update_all(payload_text: nil, payload_sha256: "0" * 64) }
    refused_by_db { AiRelease.where(id: @release.id).update_all(payload_text: nil, rubric_digest: "x") }
    refused_by_db { AiRelease.where(id: @release.id).update_all(payload_text: "teks lain") }
    old = @release.payload_sha256
    AiRelease.where(id: @release.id).update_all(payload_text: "") # "" is normalised to NULL
    @release.reload
    assert_nil @release.payload_text
    assert_equal old, @release.payload_sha256
    refused_by_db { AiRelease.where(id: @release.id).delete_all }
  end

  test "consent withdrawal erases every copy (release, AI quotes and report, stage texts, CV text, CV file); scores stay" do
    with_ai(@fake) do
      release_held!(reviewer: @reviewer)
      @fake.push(gemini_message(criteria_for(@job)))
      perform_enqueued_jobs
    end
    result = @participation.reload.screening_results.last
    assert result.criteria.any? { |c| c["quote"].present? }, "control: quotes stored"
    score = result.score
    note = ProgressionChoice.insert!({ participation_id: @participation.id, choice: "tidak_lanjut", direction: "tidak_lanjut", note: "Cerita kandidat", actor_id: staff_user("hr_pic").id, created_at: Time.current }).rows.first.first
    application = @participation.job_application
    assert application.cv.attached?
    Portal::CandidateActions.new(application.reload).withdraw_consent!
    result.reload
    assert result.criteria.all? { |c| c["quote"].nil? }
    assert_equal [score, "consent_withdrawn"], [result.score, result.screening_result_erasure.reason]
    assert_equal StageTextErasure::MARKER, ProgressionChoice.find(note).note
    assert_nil application.reload.cv_text
    refute application.cv.attached?
    assert_nil AiRelease.latest_for(@participation).payload_text
    # Without an erasure row the database refuses to touch a result (control for the trigger).
    other = ScreeningResult.where.not(id: result.id).first
    refused_by_db { ScreeningResult.where(id: result.id).update_all(score: 1) }
    assert_nil other
  end

  test "an erased version cannot be cut or released, and its page says it was erased" do
    AiReleases::Erase.call(application: @participation.job_application, reason: "retention_expired", actor: staff_user("admin"))
    @release.reload
    assert @release.erased?
    assert_raises(AiReleases::Refused) { AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [@release.cv_line_start]) }
    with_ai(@fake) do
      assert_raises(AiReleases::Refused) { AiReleases::Release.call(release: @release, user: @reviewer, confirmed: "1", seen_sha256: @release.payload_sha256) }
    end
    refused_by_db do
      AiReleaseAction.insert!({ ai_release_id: @release.id, action: "released", actor_id: @reviewer.id, checked: true,
                                payload_sha256: @release.payload_sha256, created_at: Time.current })
    end
    assert_equal "retention_expired", @release.erasure.reason
  end

  test "the retention task erases every copy at retention end, and nothing of a CV inside its period" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("glassbox:retention:erase_expired")
    with_ai(@fake) { @other = apply_with_cv!(@job, name: "Dewi Lestari") ; perform_enqueued_jobs }
    expired = @participation.job_application
    expired.update_columns(consent_at: 40.days.ago, consent_retention_days: 30)
    task = Rake::Task["glassbox:retention:erase_expired"]
    task.reenable
    out, = capture_io { task.invoke }
    assert_includes out, "retention_expired 1"
    assert_nil expired.reload.cv_text
    refute expired.cv.attached?, "the CV file is purged at retention end (D16, D32)"
    assert_nil AiRelease.latest_for(@participation).payload_text
    refute_nil AiRelease.latest_for(@other).payload_text, "a CV inside its retention period is kept"
    refute_nil @other.job_application.reload.cv_text
  end
end
