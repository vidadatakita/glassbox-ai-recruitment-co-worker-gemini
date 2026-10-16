require "test_helper"

# Blueprint §4.1 steps 7-8, D13, §5.2 "before calibration passes, no AI-only result is presented
# as final", and §1.2 "the reviewer is never the job's consultant".
class Screening::CalibrationAndReviewTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @reviewer = staff_user("reviewer")
  end

  def screen_one(criteria = criteria_for(@job), name: "Calon Tambahan")
    with_ai(@fake) do
      @fake.push(gemini_message(criteria))
      participation = apply_with_cv!(@job, name:)
      screen_and_release!
      participation.reload
    end
  end

  test "before calibration passes: an AI score exists, but no decision, and review is refused" do
    Stages::Open.call(stage: s1(@job))
    participation = screen_one(criteria_for(@job, wajib: "not_met"))
    assert_equal 1, participation.score_entries.count
    assert_nil participation.current_decision, "an uncalibrated AI result must not become a decision"
    assert_equal :in_progress, Screening::Calibration.new(@job).status
    error = assert_raises(Screening::Review::Refused) do
      Screening::Review.call(result: participation.screening_results.last, reviewer: @reviewer, verdict: "confirm")
    end
    assert_includes error.message, "Calibration has not passed"
    # Two passes, not one: at most one pass per block of ten is sampled for review, so at least one
    # of these would be decided automatically if calibration were not checked (a single pass is
    # sampled 1 time in 10, which made this check pass by luck; mutation run A10, 2026-10-10).
    passing = [screen_one(name: "Calon Lolos 1"), screen_one(name: "Calon Lolos 2")]
    assert(passing.all? { |p| p.screening_state == "done" })
    assert(passing.all? { |p| p.current_decision.nil? }, "an uncalibrated AI pass must not become a decision either")
  end

  test "calibration boundary: 3 of 20 disagreements (15%) passes, 4 of 20 (20%) fails" do
    with_ai(@fake) { calibrate!(@job, @fake, judge: ->(i) { i < 3 ? "eliminate" : "pass" }, release: true) }
    calibration = Screening::Calibration.new(@job)
    assert_equal [20, 3, :passed], [calibration.pairs.size, calibration.disagreements, calibration.status]
  end

  test "calibration fails at 4 disagreements, even before all 20 are judged" do
    participations = with_ai(@fake) do
      Array.new(20) do |i|
        @fake.push(gemini_message(criteria_for(@job)))
        apply_with_cv!(@job, name: "Calon #{i}")
      end.tap { screen_and_release! }
    end
    participations.first(4).each do |p|
      Screening::JudgeCalibration.call(participation: p, user: @job.consultant, outcome: "eliminate")
    end
    assert_equal :failed, Screening::Calibration.new(@job).status
  end

  test "after calibration passes on an open stage: unsampled passes are decided, eliminations wait for the reviewer" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    eliminated = screen_one(criteria_for(@job, wajib: "not_met"), name: "Calon Wajib Gagal")
    decided = s1(@job).participations.select(&:current_decision)
    sampled = ScreeningResult.where(sampled: true).count
    assert_equal 20 - sampled, decided.size, "every unsampled pass is decided automatically"
    assert(decided.all? { |p| p.current_decision.outcome == "pass" && p.current_decision.basis == "threshold" })
    assert_nil eliminated.current_decision, "an AI elimination is never final without the reviewer"
    queue = Screening::ReviewQueue.new(@job)
    assert_includes queue.for_review.map(&:reason), "elimination"
    assert_equal 2, sampled, "exactly 2 of the first 20 passes are sampled (1 per block of 10)"
  end

  test "the reviewer confirms an elimination: a rule decision by the reviewer, recorded" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    participation = screen_one(criteria_for(@job, wajib: "not_met"))
    decision = Screening::Review.call(result: participation.screening_results.last, reviewer: @reviewer, verdict: "confirm")
    assert_equal %w[eliminate rule wajib_not_met], [decision.outcome, decision.basis, decision.reason_code]
    assert_equal @reviewer.id, decision.decided_by_id
    review = participation.screening_reviews.sole
    assert_equal %w[confirm elimination], [review.verdict, review.reason]
  end

  test "reversing needs a note and writes a manual decision with the opposite outcome" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    participation = screen_one(criteria_for(@job, sebaiknya: "0"))  # score 0 < 60: eliminate by threshold
    result = participation.screening_results.last
    assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer: @reviewer, verdict: "reverse", note: " ") }
    decision = Screening::Review.call(result:, reviewer: @reviewer, verdict: "reverse", note: "Pengalaman gudang tertulis di halaman 2.")
    assert_equal %w[pass manual screening_review_reversed], [decision.outcome, decision.basis, decision.reason_code]
  end

  test "an unverified result can be confirmed only with the reviewer's own note" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    key = rubric_keys(@job).last
    participation = screen_one(criteria_for(@job, quotes: { key => "Kutipan karangan AI" }))
    result = participation.screening_results.last
    assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer: @reviewer, verdict: "confirm") }
    decision = Screening::Review.call(result:, reviewer: @reviewer, verdict: "confirm", note: "SIM C ada di lampiran.")
    assert_equal "manual", decision.basis
  end

  test "the job's consultant can never review: refused by the service AND by the database" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    participation = screen_one(criteria_for(@job, wajib: "not_met"))
    result = participation.screening_results.last
    # A reviewer-role user made the job's consultant: the identity rule, not the role, must stop it.
    @job.update!(consultant: @reviewer)
    error = assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer: @reviewer, verdict: "confirm") }
    assert_includes error.message, "consultant of this vacancy"

    decision = Decision.create!(participation:, outcome: "eliminate", basis: "rule", reason_code: "wajib_not_met",
                                decided_by_id: @reviewer.id, decided_at: Time.current)
    error = refused_by_database do
      ScreeningReview.create!(participation:, screening_result: result, reviewer: @reviewer, verdict: "confirm",
                              reason: "elimination", decision:, created_at: Time.current)
    end
    assert_includes error.message, "the reviewer is the job's consultant"
  end

  test "a consultant (wrong role) can never review, at either layer" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    participation = screen_one(criteria_for(@job, wajib: "not_met"))
    result = participation.screening_results.last
    assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer: @job.consultant, verdict: "confirm") }
    decision = Decision.create!(participation:, outcome: "eliminate", basis: "rule", reason_code: "wajib_not_met",
                                decided_by_id: @job.consultant.id, decided_at: Time.current)
    refused_by_database do
      ScreeningReview.create!(participation:, screening_result: result, reviewer: @job.consultant, verdict: "confirm",
                              reason: "elimination", decision:, created_at: Time.current)
    end
  end

  test "calibration is judged by the job's consultant only, once per CV per rubric" do
    participation = screen_one
    other = staff_user("consultant", email: "konsultan-lain@uji.example")
    assert_raises(Screening::JudgeCalibration::Refused) do
      Screening::JudgeCalibration.call(participation:, user: other, outcome: "pass")
    end
    assert_raises(Screening::JudgeCalibration::Refused) do
      Screening::JudgeCalibration.call(participation:, user: @reviewer, outcome: "pass")
    end
    Screening::JudgeCalibration.call(participation:, user: @job.consultant, outcome: "pass")
    assert_raises(Screening::JudgeCalibration::Refused) do
      Screening::JudgeCalibration.call(participation:, user: @job.consultant, outcome: "eliminate")
    end
  end

  test "a rubric change makes earlier results stale: they no longer count for calibration or decisions" do
    with_ai(@fake) { calibrate!(@job, @fake, release: true) }
    assert Screening::Calibration.new(@job).passed?
    @job.requirements.find_by(tier: "sebaiknya", weight: 60).update!(cv_evidence: "Riwayat kerja di gudang berpendingin")
    calibration = Screening::Calibration.new(@job)
    assert_equal [:in_progress, 0], [calibration.status, calibration.pairs.size]
    assert_equal 20, ScreeningBoard.new(@job).stale.size
  end

  test "screening results, attempts, judgements and reviews are append-only in the database" do
    participation = screen_one
    result = participation.screening_results.last
    refused_by_database { ScreeningResult.where(id: result.id).update_all(score: 0) }
    refused_by_database { ScreeningAttempt.where(participation_id: participation.id).delete_all }
  end
end
