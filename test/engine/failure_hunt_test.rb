require "test_helper"

# Test engine, feature 01. "How does this break?" - each test drives the PUBLIC model or
# service API into a state the blueprint forbids. A test here that fails is a finding and
# stays failing until the code is fixed; it is never weakened to go green.
# Spec references: blueprint §2.1 (records), §2.2 rules 3, 4, 5, 9, 13, §3.4, §4.3.
class EngineFailureHuntTest < ActiveSupport::TestCase
  def open_stage(**kw) = Stages::Open.call(stage: create_stage(**kw))

  def change_threshold(stage, value, reason: "Pool kandidat sempit")
    Stages::ChangeThreshold.call(stage:, new_threshold: value, reason:, actor_id: ScoringFactory::ACTOR_ID)
  end

  # Runs a write that skips the model inside a SAVEPOINT, so a refusal by the database rolls
  # back only the savepoint and the assertions after it can still read. Returns the refusal
  # (or nil when the database accepted the write). Without the savepoint a refused statement
  # aborts the whole test transaction (PG::InFailedSqlTransaction, re-run 2026-10-10).
  def raw_write
    ActiveRecord::Base.transaction(requires_new: true) { yield }
    nil
  rescue ActiveRecord::StatementInvalid => e
    e
  end

  # ---- Stage lock (rule 3) ------------------------------------------------------------------

  test "FINDING: the lock can be lifted through the model by clearing opened_at first" do
    stage = open_stage(threshold: 65)
    stage.update(opened_at: nil)          # opened_at is not a locked field
    stage.update(threshold: 10)           # now locked? is false
    assert_equal BigDecimal("65.0"), stage.reload.threshold,
                 "threshold moved from 65 to 10 on an opened stage with no StageChange (#{stage.stage_changes.count} logged)"
  end

  test "FINDING: an open stage reverted to draft through the model unlocks and reopens" do
    stage = open_stage(threshold: 65)
    stage.update(status: "draft", opened_at: nil)
    stage.update(threshold: 10)
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  # F-03 (re-run 2026-10-10): the original test set status "open" without opened_at and then
  # tried the threshold. The fix refuses the first step, so the test now asserts that refusal,
  # in the model and in the database, and that the stage is still the draft it was.
  test "F-03: a stage cannot be open without opened_at (model and database)" do
    stage = create_stage(threshold: 65)
    refute stage.update(status: "open"), "an open stage without opened_at was accepted by the model"
    stage.reload
    assert raw_write { Stage.where(id: stage.id).update_all(status: "open") },
           "the database accepted an open stage without opened_at"
    assert_equal ["draft", nil], [stage.reload.status, stage.opened_at]
  end

  test "F-04: update_columns cannot move the threshold of an opened stage (database guard)" do
    stage = open_stage(threshold: 65)
    assert raw_write { stage.update_columns(threshold: 10) }, "the database accepted the threshold change"
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  test "F-04: update_all cannot move the weight of an opened stage (database guard)" do
    stage = open_stage(weight: 20)
    assert raw_write { Stage.where(id: stage.id).update_all(weight: 90) }, "the database accepted the weight change"
    assert_equal 20, stage.reload.weight
  end

  test "F-01/02: the database refuses clearing or moving opened_at, and moving open back to draft" do
    stage = open_stage
    assert raw_write { Stage.where(id: stage.id).update_all(opened_at: nil) }, "opened_at cleared"
    assert raw_write { Stage.where(id: stage.id).update_all(opened_at: 1.day.ago) }, "opened_at moved"
    assert raw_write { Stage.where(id: stage.id).update_all(status: "draft") }, "open -> draft accepted"
    refute stage.reload.update(opened_at: 1.day.ago), "the model let opened_at move"
  end

  test "FINDING-candidate: an OLD StageChange can be named again to move the threshold with no new log row" do
    # The trigger accepts any StageChange whose (old, new) matches, as long as this transaction
    # names it. History 65 -> 60 (A), 60 -> 65 (B). Naming A again moves 65 -> 60 a second time,
    # and the log then ends at 65 while the stage holds 60: the log no longer explains the value.
    stage = open_stage(threshold: 65)
    change_threshold(stage, 60)
    a = stage.stage_changes.order(:id).first
    change_threshold(stage, 65)
    raw_write do
      ActiveRecord::Base.connection.select_value("SELECT set_config('glassbox.stage_change_id', '#{a.id}', true)")
      Stage.where(id: stage.id).update_all(threshold: 60)
    end
    last_logged = stage.stage_changes.order(:id).last.new_value
    assert_equal last_logged, stage.reload.threshold,
                 "stage holds #{stage.threshold.to_s('F')}, last StageChange says #{last_logged.to_s('F')}"
  end

  test "F-04: an older matching StageChange does not license a raw edit that names none" do
    stage = open_stage(threshold: 65)
    change_threshold(stage, 60)     # logs 65 -> 60
    change_threshold(stage, 65)     # logs 60 -> 65; a 65 -> 60 row now exists from an earlier transaction
    assert raw_write { Stage.where(id: stage.id).update_all(threshold: 60) },
           "the trigger accepted an edit because an old StageChange happened to match"
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  test "FINDING-candidate: the database lets an open stage with an undecided candidate be closed (update_all)" do
    # Stages::Close refuses this (§3.4) and the model refuses a plain update; the stages trigger
    # allows open -> closed without looking at decisions.
    stage = open_stage
    create_participation(stage:)
    assert raw_write { Stage.where(id: stage.id).update_all(status: "closed") },
           "the database closed a stage with an undecided candidate"
  end

  test "FINDING: a stale Stage object changes the threshold of a CLOSED stage" do
    # ChangeThreshold checks the in-memory status. Another request closed the stage; this object
    # still says "open". The stages trigger checks the StageChange but not the status.
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, 80)
    decide!(p, outcome: "pass")                          # 80 stays a pass at 70: no decision is written
    Stages::Close.call(stage: Stage.find(stage.id))      # closed through a different object
    begin
      change_threshold(stage, 70)
    rescue ArgumentError, ActiveRecord::ActiveRecordError
      nil # refused: wanted
    end
    assert_equal [BigDecimal("65.0"), 0], [stage.reload.threshold, stage.stage_changes.count],
                 "a closed stage's threshold moved and was logged"
  end

  test "the unlock is released even when the block raises" do
    stage = open_stage
    assert_raises(RuntimeError) { stage.unlock_for_change { raise "boom" } }
    refute stage.update(threshold: 10)
  end

  test "the opening save itself may set the threshold (allowed by design, opened_at_was is nil)" do
    stage = create_stage(threshold: 65)
    stage.update!(status: "open", opened_at: Time.current, threshold: 70)
    assert_equal BigDecimal("70.0"), stage.reload.threshold
    refute stage.update(threshold: 60)
  end

  # ---- ChangeThreshold boundaries --------------------------------------------------------

  test "ChangeThreshold accepts 0 and 100 on an open stage and logs each" do
    stage = open_stage(threshold: 65)
    change_threshold(stage, 100)
    change_threshold(stage, 0)
    assert_equal [BigDecimal("100.0"), BigDecimal("0.0")], stage.stage_changes.order(:id).pluck(:new_value)
    assert_equal BigDecimal("0.0"), stage.reload.threshold
  end

  test "ChangeThreshold refuses 100.1, -0.1 and nil on an open stage and changes nothing" do
    stage = open_stage(threshold: 65)
    [BigDecimal("100.1"), BigDecimal("-0.1"), nil].each do |bad|
      assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError,
                    "threshold #{bad.inspect} accepted") { change_threshold(stage, bad) }
    end
    assert_equal BigDecimal("65.0"), stage.reload.threshold
    assert_equal 0, stage.stage_changes.count
  end

  test "ChangeThreshold refuses 100.1 and nil on a draft stage" do
    stage = create_stage(threshold: 65)
    [BigDecimal("100.1"), nil].each do |bad|
      assert_raises(ActiveRecord::RecordInvalid, ArgumentError, "threshold #{bad.inspect} accepted") do
        change_threshold(stage, bad)
      end
    end
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  test "FINDING: a threshold with two decimals is stored rounded, while the StageChange and re-decision use the raw value" do
    # threshold is decimal(4,1). 62.05 is stored as 62.1 (PostgreSQL rounds half away from zero).
    # The candidate at 62.1 must then pass against what is stored.
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, BigDecimal("62.1"))
    decide!(p, outcome: "eliminate", reason_code: "below_threshold")
    change_threshold(stage, BigDecimal("62.15"))
    stored = stage.reload.threshold
    expected = Scoring::Decider.decide(score: BigDecimal("62.1"), threshold: stored).outcome.to_s
    assert_equal expected, p.reload.current_decision.outcome,
                 "stored threshold #{stored.to_s('F')} gives #{expected}, but the re-decision recorded #{p.current_decision.outcome}"
  end

  test "FINDING-candidate: ChangeThreshold runs on a CLOSED stage and flips decisions after close" do
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, 62)
    decide!(p, outcome: "eliminate", reason_code: "below_threshold")
    Stages::Close.call(stage:)
    assert_raises(StandardError, "a closed stage accepted a threshold change") { change_threshold(stage, 60) }
    assert_equal "eliminate", p.reload.current_decision.outcome
  end

  test "D37 R2: ChangeThreshold refuses a closed stage even when no decision would change" do
    # Without a decision to flip, nothing downstream raises; only the closed-stage check can stop it.
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, 90)
    decide!(p, outcome: "pass")
    Stages::Close.call(stage:)
    error = assert_raises(ArgumentError) { change_threshold(stage, 70) }
    assert_match(/the stage is already closed/, error.message)
    assert_equal [BigDecimal("65.0"), 0], [stage.reload.threshold, stage.stage_changes.count]
  end

  # Run 3 (2026-10-10): the trigger also refuses a stale object's change (F-19), but with a raw
  # PG error. D37 R2's refusal is "the stage is already closed", which is what the operator must read, so
  # the service has to see the closed status itself (mutant L01 survived without this test).
  test "D37 R2: a stale object gets the 'the stage is already closed' refusal, not a database error" do
    stage = open_stage(threshold: 65)
    Stages::Close.call(stage: Stage.find(stage.id))
    error = assert_raises(ArgumentError) { change_threshold(stage, 70) }
    assert_match(/the stage is already closed/, error.message)
    assert_equal 0, stage.stage_changes.count
  end

  test "ChangeThreshold: an unchanged outcome creates no new decision" do
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, 80)
    decide!(p, outcome: "pass")
    assert_no_difference("Decision.count") { change_threshold(stage, 70) }
  end

  test "ChangeThreshold: raising the line eliminates a former pass, and the new row supersedes it" do
    stage = open_stage(threshold: 60)
    p = create_participation(stage:)
    add_score(p, 62)
    first = decide!(p, outcome: "pass")
    change_threshold(stage, BigDecimal("62.1"))
    current = p.reload.current_decision
    assert_equal ["eliminate", "threshold", first.id], [current.outcome, current.basis, current.supersedes_id]
    assert_equal 2, p.decisions.count
  end

  test "ChangeThreshold re-decides EVERY threshold-based participation, including the last one" do
    stage = open_stage(threshold: 65)
    ps = [61, 62, 63].map do |score|
      p = create_participation(stage:)
      add_score(p, score)
      decide!(p, outcome: "eliminate", reason_code: "below_threshold")
      p
    end
    change_threshold(stage, 60)
    assert_equal %w[pass pass pass], ps.map { |p| p.reload.current_decision.outcome }
  end

  test "ChangeThreshold: exactly at the new line passes" do
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    add_score(p, 62)
    decide!(p, outcome: "eliminate", reason_code: "below_threshold")
    change_threshold(stage, 62)
    assert_equal "pass", p.reload.current_decision.outcome
  end

  test "ChangeThreshold: on a review stage, raising the line turns a pass into review, not eliminate (rule 13)" do
    stage = open_stage(threshold: 60, review_below_threshold: true)
    p = create_participation(stage:)
    add_score(p, 62)
    decide!(p, outcome: "pass")
    change_threshold(stage, 70)
    assert_equal ["review", "threshold"], [p.reload.current_decision.outcome, p.current_decision.basis]
  end

  # D37 R1 (2026-10-10) settles the earlier SPEC CONFLICT: rule 13 beats rule 3's general
  # wording. A threshold change never touches a review; only a person clears it.
  test "D37 R1: lowering the line leaves a review untouched and writes no decision" do
    stage = open_stage(threshold: 60, review_below_threshold: true)
    p = create_participation(stage:)
    add_score(p, 55)
    review = decide!(p, outcome: "review", reason_code: "below_threshold_review")
    assert_no_difference("Decision.count") { change_threshold(stage, 50) }
    assert_equal review, p.reload.current_decision
  end

  test "D37 R1: raising the line further leaves a review untouched too" do
    stage = open_stage(threshold: 60, review_below_threshold: true)
    p = create_participation(stage:)
    add_score(p, 55)
    review = decide!(p, outcome: "review", reason_code: "below_threshold_review")
    assert_no_difference("Decision.count") { change_threshold(stage, 70) }
    assert_equal review, p.reload.current_decision
  end

  test "ChangeThreshold re-decides from the CURRENT score, not a superseded one" do
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    old = add_score(p, 50)
    add_score(p, 63, supersedes: old, reason: "typo")
    decide!(p, outcome: "eliminate", reason_code: "below_threshold")
    change_threshold(stage, 60)
    assert_equal "pass", p.reload.current_decision.outcome   # 63 >= 60; the superseded 50 would eliminate
  end

  test "FINDING-candidate: one threshold-based decision without a score blocks the whole threshold change" do
    # The model accepts a threshold decision on a participation with no score entry. The
    # re-decision then raises and the whole stage's change rolls back. Not silent, but one bad
    # row stops a legitimate change for every candidate. The decision should have been refused.
    stage = open_stage(threshold: 65)
    p = create_participation(stage:)
    assert_raises(ActiveRecord::RecordInvalid, "a threshold-based decision with no score was accepted") do
      decide!(p, outcome: "pass")
    end
  end

  test "ChangeThreshold on a draft stage writes no StageChange (spec: only after the stage has opened)" do
    stage = create_stage(threshold: 65)
    change_threshold(stage, 70)
    assert_equal [BigDecimal("70.0"), 0], [stage.reload.threshold, stage.stage_changes.count]
  end

  # ---- Decisions (rules 4, 5) ------------------------------------------------------------

  test "FINDING: a threshold PASS can be recorded on a no-show participation" do
    stage = open_stage
    p = create_participation(stage:, attendance: "no_show")
    assert_raises(ActiveRecord::RecordInvalid, "a no-show was passed by threshold") do
      decide!(p, outcome: "pass", basis: "threshold")
    end
  end

  test "FINDING: a score entry can be recorded for a no-show participation (rule 5: no score entry)" do
    p = create_participation(stage: open_stage, attendance: "no_show")
    assert_raises(ActiveRecord::RecordInvalid, "a no-show got a score entry") { add_score(p, 70) }
  end

  # D37 F-13: on a closed stage only a MANUAL decision with a reason is allowed (the E21
  # correction path); threshold and rule decisions are refused.
  test "D37 F-13: a closed stage refuses threshold and rule decisions" do
    stage = open_stage
    p = create_participation(stage:)
    add_score(p, 80)
    first = decide!(p, outcome: "pass")
    Stages::Close.call(stage:)
    assert_raises(ActiveRecord::RecordInvalid, "threshold decision after close") do
      decide!(p, outcome: "eliminate", basis: "threshold", reason_code: "below_threshold", supersedes: first)
    end
    assert_raises(ActiveRecord::RecordInvalid, "rule decision after close") do
      decide!(p, outcome: "eliminate", basis: "rule", reason_code: "no_show", supersedes: first)
    end
    assert_equal first, p.reload.current_decision
  end

  test "D37 F-13: a closed stage accepts a manual decision with a note, and refuses one with a blank note" do
    stage = open_stage
    p = create_participation(stage:)
    add_score(p, 80)
    first = decide!(p, outcome: "pass")
    Stages::Close.call(stage:)
    assert_raises(ActiveRecord::RecordInvalid) do
      decide!(p, outcome: "eliminate", basis: "manual", reason_code: "override", note: " ", supersedes: first)
    end
    second = decide!(p, outcome: "eliminate", basis: "manual", reason_code: "override",
                        note: "Keberatan kandidat ditolak setelah ditinjau", supersedes: first)
    assert_equal second, p.reload.current_decision
  end

  test "FINDING-candidate: a decision can be recorded on a DRAFT (never opened) stage" do
    p = create_participation(stage: create_stage)
    add_score(p, 80)
    assert_raises(ActiveRecord::RecordInvalid, "a draft stage accepted a decision") { decide!(p, outcome: "pass") }
  end

  test "a manual decision without an actor is refused by the model and by the database" do
    p = create_participation(stage: open_stage)
    d = Decision.new(participation: p, outcome: "pass", basis: "manual", reason_code: "override", note: "x",
                     decided_by_id: nil, decided_at: Time.current)
    refute d.valid?
    assert_raises(ActiveRecord::StatementInvalid) { d.save!(validate: false) }
  end

  test "a manual decision with a blank note is refused by the model" do
    p = create_participation(stage: open_stage)
    assert_raises(ActiveRecord::RecordInvalid) do
      decide!(p, outcome: "pass", basis: "manual", reason_code: "override", note: "   ")
    end
  end

  test "FINDING-candidate: a manual decision with an empty-string note passes the DATABASE check" do
    # The check is note IS NOT NULL; '' and '  ' satisfy it. Any write that skips the model
    # (insert_all, raw SQL, a later import) records an unexplained override.
    p = create_participation(stage: open_stage)
    d = Decision.new(participation: p, outcome: "pass", basis: "manual", reason_code: "override", note: "",
                     decided_by_id: 1, decided_at: Time.current)
    assert_raises(ActiveRecord::StatementInvalid, "the database accepted a manual override with an empty note") do
      d.save!(validate: false)
    end
  end

  test "a first decision naming another participation's decision as superseded is refused" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    add_score(a, 80)
    add_score(b, 80)
    da = decide!(a, outcome: "pass")
    assert_raises(ActiveRecord::RecordInvalid) { decide!(b, outcome: "pass", supersedes: da) }
    assert_equal da, a.reload.current_decision, "a's decision must stay current"
  end

  test "a second decision naming ANOTHER participation's current decision is refused" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    add_score(a, 80)
    add_score(b, 80)
    da = decide!(a, outcome: "pass")
    decide!(b, outcome: "pass")
    assert_raises(ActiveRecord::RecordInvalid) do
      decide!(b, outcome: "eliminate", basis: "manual", reason_code: "override", note: "x", supersedes: da)
    end
  end

  test "F-10: the database refuses a decision superseding a decision of another participation" do
    # The model refuses it (above). A write that skips the model would make a's decision
    # non-current, so a would silently have NO decision. Both get a score: since F-06 a threshold
    # decision needs one (setup fixed on the 2026-10-10 re-run).
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    add_score(a, 80)
    add_score(b, 80)
    da = Decision.create!(participation: a, outcome: "pass", basis: "threshold", reason_code: "x", decided_at: Time.current)
    rogue = Decision.new(participation: b, outcome: "eliminate", basis: "threshold", reason_code: "x",
                         decided_at: Time.current, supersedes: da)
    begin
      rogue.save!(validate: false)
    rescue ActiveRecord::StatementInvalid
      # refused by the database: wanted
    end
    assert_equal da, a.reload.current_decision, "participation a lost its decision to a row of participation b"
  end

  test "FINDING: two first decisions for one participation (racing requests) are both current" do
    # supersedes_id is unique, but two rows with supersedes_id NULL are not covered. Mirrors the
    # builder's own race test for score entries: skip validation to act as the second request.
    p = create_participation(stage: open_stage)
    add_score(p, 80)
    decide!(p, outcome: "pass")
    begin
      Decision.new(participation: p, outcome: "eliminate", basis: "threshold", reason_code: "below_threshold",
                   decided_at: Time.current).save!(validate: false)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid
      # refused by the database: wanted
    end
    assert_equal 1, p.decisions.current.count, "participation has #{p.decisions.current.count} current decisions"
  end

  # ---- Score entries (rule 9) ------------------------------------------------------------

  test "a score entry cannot supersede an entry of another participation" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    ea = add_score(a, 70)
    assert_raises(ActiveRecord::RecordInvalid) { add_score(b, 90, supersedes: ea, reason: "x") }
    assert_equal BigDecimal("70.0"), a.reload.current_score
  end

  test "FINDING: the database lets a score entry supersede an entry of another participation" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    ea = add_score(a, 70)
    begin
      ScoreEntry.new(participation: b, value: 90, entered_by_id: 2, entered_at: Time.current, supersedes: ea,
                     correction_reason: "x").save!(validate: false)
    rescue ActiveRecord::StatementInvalid
      # refused by the database: wanted
    end
    assert_equal BigDecimal("70.0"), a.reload.current_score, "a's only score vanished (now #{a.current_score.inspect})"
  end

  test "an already-superseded entry cannot be superseded again through the model" do
    p = create_participation(stage: open_stage)
    a = add_score(p, 60)
    add_score(p, 64, supersedes: a, reason: "first")
    assert_raises(ActiveRecord::RecordInvalid) { add_score(p, 66, supersedes: a, reason: "second") }
  end

  test "supersede chain of three: only the last is current, for scores and for decisions" do
    p = create_participation(stage: open_stage)
    a = add_score(p, 50)
    b = add_score(p, 60, supersedes: a, reason: "1")
    c = add_score(p, 70, supersedes: b, reason: "2")
    assert_equal [c.id], p.score_entries.current.pluck(:id)
    assert_equal BigDecimal("70.0"), p.current_score

    d1 = decide!(p, outcome: "pass")
    d2 = decide!(p, outcome: "eliminate", basis: "manual", reason_code: "o", note: "n", supersedes: d1)
    d3 = decide!(p, outcome: "pass", basis: "manual", reason_code: "o", note: "n", supersedes: d2)
    assert_equal [d3.id], p.decisions.current.pluck(:id)
    assert_equal d3, p.current_decision
  end

  test "current scope with two interviewers, each corrected once, keeps one row per interviewer" do
    p = create_participation(stage: open_stage)
    i1 = add_score(p, 50)
    i2 = add_score(p, 90)
    add_score(p, 60, supersedes: i1, reason: "1")
    add_score(p, 80, supersedes: i2, reason: "2")
    assert_equal BigDecimal("70.0"), p.current_score   # (60 + 80) / 2
  end

  test "current scope is not fooled by another participation's corrections" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    add_score(a, 70)
    eb = add_score(b, 40)
    add_score(b, 45, supersedes: eb, reason: "x")
    assert_equal BigDecimal("70.0"), a.current_score
    assert_equal BigDecimal("45.0"), b.current_score
  end

  test "score value boundaries: 0 and 100 accepted, -0.1 and 100.1 refused by model and database" do
    p = create_participation(stage: open_stage)
    add_score(p, 0)
    add_score(p, 100)
    [BigDecimal("-0.1"), BigDecimal("100.1")].each do |v|
      assert_raises(ActiveRecord::RecordInvalid) { add_score(p, v) }
      assert_raises(ActiveRecord::StatementInvalid) do
        ScoreEntry.new(participation: p, value: v, entered_by_id: 1, entered_at: Time.current).save!(validate: false)
      end
    end
  end

  test "FINDING: a two-decimal score is stored rounded by the database but kept unrounded in memory" do
    # value is decimal(4,1). 70.05 must be one decimal (rule 1); the record should either refuse
    # it or hold what the database holds.
    p = create_participation(stage: open_stage)
    e = add_score(p, BigDecimal("70.05"))
    assert_equal e.reload.value, ScoreEntry.find(e.id).value
    assert_equal BigDecimal("70.1"), e.value
    fresh = add_score(create_participation(stage: p.stage), BigDecimal("64.95"))
    assert_equal fresh.value, ScoreEntry.find(fresh.id).value,
                 "in memory #{fresh.value.to_s('F')} vs stored #{ScoreEntry.find(fresh.id).value.to_s('F')}"
  end

  # ---- Close (§3.4) ------------------------------------------------------------------------

  test "FINDING-candidate: a DRAFT stage can be closed without ever opening" do
    stage = create_stage
    assert_raises(StandardError, "a draft stage was closed") { Stages::Close.call(stage:) }
    assert_equal "draft", stage.reload.status
  end

  def close_capturing_log(stage)
    io = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    Stages::Close.call(stage:)
    io.string
  ensure
    Rails.logger = old
  end

  test "D37 F-14b: an open stage with zero participations closes, and the log says so" do
    stage = open_stage
    log = close_capturing_log(stage)
    assert_equal "closed", stage.reload.status
    assert_match(/event=stage_closed_empty stage_id=#{stage.id}\b/, log)
  end

  test "D37 F-14b control: a stage WITH participants does not log stage_closed_empty" do
    stage = open_stage
    p = create_participation(stage:)
    add_score(p, 80)
    decide!(p, outcome: "pass")
    refute_match(/stage_closed_empty/, close_capturing_log(stage))
  end

  test "Close: a closed stage closed again is refused or a no-op, never a status regression" do
    stage = open_stage
    Stages::Close.call(stage:)
    begin
      Stages::Close.call(stage:)
    rescue StandardError
      nil # refusing is acceptable
    end
    assert_equal "closed", stage.reload.status
  end

  test "Close: a participation with only a superseded decision chain ending in pass is decided" do
    stage = open_stage
    p = create_participation(stage:)
    add_score(p, 50)
    d1 = decide!(p, outcome: "review", reason_code: "below_threshold_review")
    decide!(p, outcome: "pass", basis: "manual", reason_code: "o", note: "n", supersedes: d1)
    assert_equal "closed", Stages::Close.call(stage:).status
  end

  test "Close: review superseded by eliminate is decided; pass superseded by review is not" do
    stage = open_stage
    p = create_participation(stage:)
    add_score(p, 50)
    d1 = decide!(p, outcome: "pass")
    decide!(p, outcome: "review", basis: "manual", reason_code: "o", note: "n", supersedes: d1)
    assert_raises(Stages::Close::Undecided) { Stages::Close.call(stage:) }
  end

  test "Close: every undecided application is named, not only the first" do
    stage = open_stage
    a = create_participation(stage:)
    b = create_participation(stage:)
    error = assert_raises(Stages::Close::Undecided) { Stages::Close.call(stage:) }
    assert_includes error.message, a.job_application_id.to_s
    assert_includes error.message, b.job_application_id.to_s
  end

  test "FINDING: Stages::Close can be bypassed by setting status closed through the model" do
    stage = open_stage
    create_participation(stage:)   # undecided
    refute stage.update(status: "closed"), "an open stage with an undecided candidate closed via update"
  end

  test "Open decides a knocked-out application by rule, and leaves a clean one undecided (rule 16)" do
    stage = create_stage
    out = Participation.create!(job_application: JobApplication.create!(job: stage.job, knockout_answers: { "q1" => "tidak" }),
                                stage:, attendance: "pending")
    clean = Participation.create!(job_application: JobApplication.create!(job: stage.job, knockout_answers: { "q1" => "ya" }),
                                  stage:, attendance: "pending")
    Stages::Open.call(stage:)
    d = out.reload.current_decision
    assert_equal ["eliminate", "rule", "knockout"], [d&.outcome, d&.basis, d&.reason_code]
    assert_nil clean.reload.current_decision
  end

  test "FINDING-candidate: a no-show passed by a manual override is counted twice in the stage figures" do
    # D37 allows a manual pass on anyone (rule 4). StageStats counts it in passed AND no_shows,
    # so the buckets add up to more than the participants (rule 9 tie-out).
    rows = [Scoring::StageStats::Row.new(attendance: :no_show, score: nil, outcome: :pass),
            Scoring::StageStats::Row.new(attendance: :attended, score: 70, outcome: :pass)]
    s = Scoring::StageStats.call(rows)
    assert_equal s.participants, s.passed + s.eliminated + s.no_shows + s.in_review,
                 "buckets #{[s.passed, s.eliminated, s.no_shows, s.in_review].inspect} vs participants #{s.participants}"
  end

  test "F-06: a candidate scored while attended, then marked no-show, cannot be passed by threshold" do
    p = create_participation(stage: open_stage)
    add_score(p, 90)
    p.update!(attendance: "no_show")
    assert_raises(ActiveRecord::RecordInvalid, "a no-show with a leftover score was passed by threshold") do
      decide!(p, outcome: "pass", basis: "threshold")
    end
  end

  test "the model itself refuses closed -> open and open -> draft (not only the database trigger)" do
    stage = open_stage
    Stages::Close.call(stage:)
    refute stage.update(status: "open"), "closed -> open accepted by the model"
    assert_includes stage.errors[:status].join, "cannot move from closed to open"
  end

  test "Open: only a draft stage opens; open and closed are refused" do
    stage = open_stage
    assert_raises(ArgumentError) { Stages::Open.call(stage:) }
    Stages::Close.call(stage:)
    assert_raises(ArgumentError) { Stages::Open.call(stage:) }
  end
end
