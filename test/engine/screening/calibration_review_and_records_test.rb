require "test_helper"
require_relative "screening_engine_support"

# D13 / blueprint §4.1 step 7 (calibration), step 8 (reviewer, 10% sample), step 9 (traceability),
# §5.1 row 4 style database refusals for the four new append-only tables, and ONP-19 (no CV text
# or personal data in the log lines a screening run writes).
class EngineScreeningCalibrationTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    @fake = FakeGemini.new
  end

  def calibrate_with_disagreements(n, open: true)
    Stages::Open.call(stage: s1(@job)) if open
    with_ai(@fake) { calibrate!(@job, @fake, judge: ->(i) { i < n ? "eliminate" : "pass" }) }
    Screening::Calibration.new(@job)
  end

  test "D13 boundary: exactly 3 of 20 disagreements (15%) passes" do
    cal = calibrate_with_disagreements(SPEC_MAX_DISAGREEMENTS_THAT_PASS)
    assert_equal [SPEC_CALIBRATION_SIZE, 3, :passed], [cal.pairs.size, cal.disagreements, cal.status]
  end

  test "D13 boundary: 4 of 20 (20%, more than 15%) fails, and NO AI result becomes a decision" do
    cal = calibrate_with_disagreements(SPEC_MAX_DISAGREEMENTS_THAT_PASS + 1)
    assert_equal [4, :failed], [cal.disagreements, cal.status]
    assert_equal 0, Screening::Finalize.call(@job)
    assert_equal 0, Decision.joins(:participation).where(participations: { stage_id: s1(@job).id }).count
  end

  test "fewer than 20 applications: calibration never passes, no AI result is ever a decision" do
    Stages::Open.call(stage: s1(@job))
    with_ai(@fake) do
      ps = Array.new(SPEC_CALIBRATION_SIZE - 1) do |i|
        @fake.push(gemini_message(criteria_for(@job)))
        apply_with_cv!(@job, name: "Calon Kecil #{i}")
      end
      drain_jobs!
      ps.each { |p| Screening::JudgeCalibration.call(participation: p, user: @job.consultant, outcome: "pass") }
    end
    cal = Screening::Calibration.new(@job)
    assert_equal [19, 0, :in_progress], [cal.pairs.size, cal.disagreements, cal.status]
    assert_equal 0, Screening::Finalize.call(@job)
    assert_equal 0, Decision.joins(:participation).where(participations: { stage_id: s1(@job).id }).count
  end

  test "the calibration set is the first 20 by arrival: the 21st cannot be judged, and judging twice is refused" do
    ps = calibrate_with_disagreements(0, open: false)
    late = with_ai(@fake) do
      @fake.push(gemini_message(criteria_for(@job)))
      apply_with_cv!(@job, name: "Calon Ke 21").tap { drain_jobs! }
    end
    assert_equal :passed, ps.status
    error = assert_raises(Screening::JudgeCalibration::Refused) do
      Screening::JudgeCalibration.call(participation: late, user: @job.consultant, outcome: "eliminate")
    end
    assert_includes error.message, "not one of the 20 calibration CVs"
    first = ps.participations.first
    assert_raises(Screening::JudgeCalibration::Refused) do
      Screening::JudgeCalibration.call(participation: first, user: @job.consultant, outcome: "eliminate")
    end
  end
end

class EngineScreeningReviewerTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @reviewer = staff_user("reviewer")
    calibrated_open_job!(@job, @fake)
  end

  def screen(criteria, name)
    participation, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(criteria)], name:)
    participation
  end

  test "every elimination and every unverified result waits for the reviewer; Finalize decides none of them" do
    sebaiknya = keys_of(@job, "sebaiknya")
    wajib = keys_of(@job, "wajib").first
    cases = {
      "wajib" => screen(criteria_for(@job, wajib: "not_met"), "Calon Wajib"),
      "threshold" => screen(criteria_for(@job, sebaiknya: "0"), "Calon Skor Rendah"),
      "unverified_pass" => screen(criteria_with(@job, { sebaiknya[0] => { judgement: "3", quote: "Supervisor 9 tahun di PT Karangan" } }), "Calon Kutipan"),
      "unverified_wajib" => screen(criteria_with(@job, { wajib => { judgement: "met", quote: "S2 Teknik Industri" } }), "Calon Wajib Karangan")
    }
    Screening::Finalize.call(@job)
    queue = Screening::ReviewQueue.new(@job)
    reasons = cases.transform_values { |p| queue.for_review.find { |i| i.participation.id == p.id }&.reason }
    assert_equal({ "wajib" => "elimination", "threshold" => "elimination", "unverified_pass" => "unverified",
                   "unverified_wajib" => "unverified" }, reasons)
    cases.each_value { |p| assert_nil p.reload.current_decision, "no automatic decision for #{p.job_application.candidate.name}" }
  end

  # Three-role model (17 Oct 2026): review is an HR manager action. Both HR admin persons (old
  # consultant and HR PIC) are refused; owner is now an HR manager and superadmin passes every role
  # check, so neither is in the refused list any more.
  test "HR admin persons are refused by the service; nothing is written" do
    p = screen(criteria_for(@job, wajib: "not_met"), "Calon Peran")
    result = p.screening_results.sole
    %w[consultant hr_pic hr_admin].each do |role|
      error = assert_raises(Screening::Review::Refused, role) do
        Screening::Review.call(result:, reviewer: staff_user(role), verdict: "confirm")
      end
      assert_includes error.message, "Only the HR Manager"
    end
    assert_equal 0, ScreeningReview.count
    assert_nil p.reload.current_decision
    Screening::Review.call(result:, reviewer: @reviewer, verdict: "confirm")
    assert_equal 1, ScreeningReview.count, "control: the real reviewer can review"
  end

  # Actor who benefits (load-bearing-tests rule 19): the job's consultant is paid by the funnel.
  test "the job's consultant can never be the reviewer, at the service and at the database" do
    p = screen(criteria_for(@job, wajib: "not_met"), "Calon Konsultan")
    result = p.screening_results.sole
    @job.update!(consultant: @reviewer)
    error = assert_raises(Screening::Review::Refused) { Screening::Review.call(result:, reviewer: @reviewer, verdict: "confirm") }
    assert_equal "The reviewer cannot be the consultant of this vacancy.", error.message
    decision = Decision.create!(participation: p, outcome: "eliminate", basis: "rule", reason_code: "wajib_not_met",
                                decided_by_id: @reviewer.id, decided_at: Time.current)
    db_error = refused_by_database do
      ScreeningReview.insert!({ participation_id: p.id, screening_result_id: result.id, reviewer_id: @reviewer.id,
                                verdict: "confirm", reason: "elimination", decision_id: decision.id, created_at: Time.current })
    end
    assert_includes db_error.message, "the reviewer is the job's consultant"
  end
end

class EngineScreeningSampleTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  test "the 10% sample: exactly one in every block of ten, reproducible from the seed alone" do
    seed = "a" * 32
    picks = (1..1000).select { |o| Screening::ReviewSample.sampled?(seed:, ordinal: o) }
    assert_equal 100, picks.size
    assert_equal Array.new(100, 1), picks.group_by { |o| (o - 1) / 10 }.values.map(&:size)
    assert_equal picks, (1..1000).select { |o| Screening::ReviewSample.sampled?(seed:, ordinal: o) }, "same seed, same sample"
    other = (1..1000).select { |o| Screening::ReviewSample.sampled?(seed: "b" * 32, ordinal: o) }
    refute_equal picks, other, "the sample depends on the seed"
  end

  test "stored sample flags recompute from the stored seed, and re-running does not re-draw the sample" do
    job = screening_job
    fake = FakeGemini.new
    with_ai(fake) do
      ps = Array.new(12) do |i|
        fake.push(gemini_message(criteria_for(job)))
        apply_with_cv!(job, name: "Calon Sampel #{i}")
      end
      drain_jobs!
      seed = job.reload.screening_sample_seed
      assert seed.present?
      results = ScreeningResult.where(participation: ps).order(:pass_ordinal).to_a
      assert_equal (1..12).to_a, results.map(&:pass_ordinal)
      results.each { |r| assert_equal Screening::ReviewSample.sampled?(seed:, ordinal: r.pass_ordinal), r.sampled }
      # Re-running the job, pressing Mulai screening, re-enqueueing: no new ordinal, same seed.
      ps.each { |p| ScreenParticipationJob.perform_now(p.id) }
      Screening::Start.call(job)
      drain_jobs!
      assert_equal 12, ScreeningResult.where(participation: ps).count
      assert_equal seed, job.reload.screening_sample_seed
      assert_equal 12, ScreeningResult.joins(participation: :stage).where(stages: { job_id: job.id }).maximum(:pass_ordinal)
    end
  end

  test "a failed screening that is retried takes the next ordinal once, never an earlier sampled slot" do
    job = screening_job
    fake = FakeGemini.new(refusal_message, gemini_message(criteria_for(job)), gemini_message(criteria_for(job)))
    with_ai(fake) do
      failed = apply_with_cv!(job, name: "Calon Gagal Dulu")
      drain_jobs!
      ok = apply_with_cv!(job, name: "Calon Lancar")
      drain_jobs!
      Screening::Start.call(job)
      drain_jobs!
      assert_equal [1, 2], [ok.screening_results.sole.pass_ordinal, failed.screening_results.sole.pass_ordinal]
    end
  end
end

class EngineScreeningRecordsTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  setup do
    @job = screening_job
    fake = FakeGemini.new
    calibrated_open_job!(@job, fake)
    @p, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(criteria_for(@job, wajib: "not_met"), model: "gemini-3.8-flash-002")],
                                         name: "Calon Catatan")
    @result = @p.screening_results.sole
    Screening::Review.call(result: @result, reviewer: staff_user("reviewer"), verdict: "confirm")
  end

  test "the S1 ScoreEntry and the result store the model that answered and the prompt version" do
    entry = @p.score_entries.sole
    assert_equal ["gemini-3.8-flash-002", Screening::PROMPT_VERSION], [entry.model_id, entry.prompt_version]
    assert_equal ["gemini-3.8-flash-002", Screening::PROMPT_VERSION], [@result.model_id, @result.prompt_version]
    assert_match(/\As1-\d{4}-\d{2}-\d{2}\.\d+\z/, entry.prompt_version)
    refused_by_database { ScoreEntry.where(id: entry.id).update_all(prompt_version: nil) }
    error = refused_by_database do
      ScoreEntry.insert!({ participation_id: @p.id, value: 10, entered_by_id: 0, model_id: "gemini-3.8-flash",
                           entered_at: Time.current, event_at: Time.current, ratings: {} })
    end
    assert_includes error.message, "score_entries_ai_trace_complete", "a model id without a prompt version is refused"
  end

  TABLES = %w[screening_results screening_attempts calibration_judgements screening_reviews].freeze

  test "the four append-only tables refuse UPDATE and DELETE at the database" do
    conn = ActiveRecord::Base.connection
    TABLES.each do |table|
      assert_operator conn.select_value("SELECT count(*) FROM #{table}").to_i, :>, 0, "control: #{table} has rows"
      e1 = refused_by_database { conn.execute("UPDATE #{table} SET created_at = created_at") }
      assert_includes e1.message, "#{table} is append-only: UPDATE refused"
      e2 = refused_by_database { conn.execute("DELETE FROM #{table}") }
      assert_match(/#{table} is append-only: DELETE refused|violates foreign key/, e2.message)
    end
    e3 = refused_by_database { conn.execute("DELETE FROM screening_reviews") }
    assert_includes e3.message, "screening_reviews is append-only: DELETE refused"
    conn.execute("UPDATE participations SET screening_state_at = screening_state_at WHERE id = #{@p.id}") # control: a mutable table
  end

  test "the four append-only tables refuse TRUNCATE at the database (by the trigger, not by a foreign key)" do
    conn = ActiveRecord::Base.connection
    { "screening_attempts" => "screening_attempts", "calibration_judgements" => "calibration_judgements",
      "screening_reviews" => "screening_reviews", "screening_results, screening_reviews" => nil }.each do |list, named|
      error = refused_by_database { conn.execute("TRUNCATE #{list}") }
      assert_match(/is append-only: TRUNCATE refused/, error.message, list)
      assert_includes error.message, named if named
    end
  end

  # ONP-19: the log lines written WHILE a screening runs carry ids, never CV text or personal data.
  test "a screening run writes no CV text or personal data to the Rails log" do
    io = StringIO.new
    log = ActiveSupport::Logger.new(io)
    log.level = :debug
    fake = FakeGemini.new
    participation = nil
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      participation = apply_with_cv!(@job)               # feature 02 writes the application (not this run)
      Rails.logger.broadcast_to(log)
      begin
        drain_jobs!
      ensure
        Rails.logger.stop_broadcasting_to(log)
      end
    end
    lines = io.string
    assert_includes lines, "ScreenParticipationJob", "control: the run's own lines were captured"
    assert_match(/INSERT INTO "screening_results"/, lines, "control: SQL of the run was captured")
    assert_equal "done", participation.reload.screening_state
    leaks = (PROTECTED.first(16) + EVIDENCE + ["Rina", "rina", "Bekasi, 12-03-1995"]).select { |v| lines.include?(v) }
    assert_empty leaks, "personal data or CV text in the log: #{leaks.inspect}"
  end
end
