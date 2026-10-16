require "test_helper"

# Test engine, feature 01. Guards that must hold IN THE DATABASE, not only in the model
# (blueprint §5.1 row 4: "UPDATE / DELETE on ScoreEntry and Decision refused by the database").
# Every write here skips the model on purpose (raw SQL, update_all, save(validate: false)).
class EngineDbGuardsTest < ActiveSupport::TestCase
  def sql(statement) = ActiveRecord::Base.connection.execute(statement)

  setup do
    @stage = Stages::Open.call(stage: create_stage)
    @p = create_participation(stage: @stage)
    @entry = add_score(@p, 70)
    @decision = decide!(@p, outcome: "pass")
    @change = StageChange.create!(stage: @stage, field: "threshold", old_value: 65, new_value: 60, reason: "r",
                                  changed_by_id: 1, changed_at: Time.current)
  end

  # Each of the 3 tables x {UPDATE, DELETE} is refused. The builder's suite covers 4 of the 6
  # cells; DELETE on decisions and UPDATE on stage_changes are covered here.
  { "score_entries" => "value = 1", "decisions" => "outcome = 'eliminate'", "stage_changes" => "reason = 'x'" }
    .each do |table, set|
    test "the database refuses UPDATE on #{table}" do
      id = { "score_entries" => @entry.id, "decisions" => @decision.id, "stage_changes" => @change.id }[table]
      error = assert_raises(ActiveRecord::StatementInvalid) { sql("UPDATE #{table} SET #{set} WHERE id = #{id}") }
      assert_match(/append-only/, error.message)
    end

    test "the database refuses DELETE on #{table}" do
      id = { "score_entries" => @entry.id, "decisions" => @decision.id, "stage_changes" => @change.id }[table]
      error = assert_raises(ActiveRecord::StatementInvalid) { sql("DELETE FROM #{table} WHERE id = #{id}") }
      assert_match(/append-only/, error.message)
    end

    # F-11. The refused TRUNCATE runs in a savepoint so the count after it can still be read
    # (without it the aborted transaction raised PG::InFailedSqlTransaction, re-run 2026-10-10).
    test "F-11: TRUNCATE #{table} is refused and the history survives" do
      refusal = raw_write { sql("TRUNCATE #{table} CASCADE") }
      count = sql("SELECT count(*) AS n FROM #{table}").first["n"].to_i
      assert_operator count, :>=, 1, "TRUNCATE #{table} succeeded and left #{count} rows"
      assert_match(/append-only/, refusal&.message.to_s)
    end
  end

  # TRUNCATE on a PARENT table with CASCADE reaches the append-only tables through their
  # foreign keys. The statement trigger must fire for the cascaded tables too.
  %w[participations stages jobs job_applications].each do |parent|
    test "F-11: TRUNCATE #{parent} CASCADE cannot wipe score entries and decisions" do
      raw_write { sql("TRUNCATE #{parent} CASCADE") }
      left = %w[score_entries decisions stage_changes].map { |t| sql("SELECT count(*) AS n FROM #{t}").first["n"].to_i }
      assert left.all?(&:positive?), "after TRUNCATE #{parent} CASCADE: score_entries/decisions/stage_changes = #{left.inspect}"
    end
  end

  test "F-09: the database refuses a second FIRST decision for one participation" do
    refusal = raw_write do
      Decision.new(participation: @p, outcome: "eliminate", basis: "threshold", reason_code: "x",
                   decided_at: Time.current).save!(validate: false)
    end
    assert refusal, "two first decisions were stored"
    assert_equal 1, @p.decisions.current.count
  end

  test "F-09 control: a first decision for a DIFFERENT participation is still accepted" do
    other = create_participation(stage: @stage)
    add_score(other, 50)
    assert_nil raw_write { decide!(other, outcome: "eliminate", reason_code: "below_threshold") }
  end

  test "F-16: the database refuses a manual note that is empty or only spaces" do
    ["", "   "].each do |note|
      refusal = raw_write do
        Decision.new(participation: create_participation(stage: @stage), outcome: "pass", basis: "manual",
                     reason_code: "o", note:, decided_by_id: 1, decided_at: Time.current).save!(validate: false)
      end
      assert refusal, "manual note #{note.inspect} accepted by the database"
    end
  end

  # ---- Run 3 (2026-10-10): stages_lifecycle after migration ...0006 ---------------------------
  # Every test below exists because a mutant of the trigger survived the suite without it
  # (DL1, DL2, DL4, DL5, DL7, DL8 in docs/test-engine/mutants-01.md). The service layer refuses
  # the same moves first, so only a write that skips the model reaches these trigger branches.

  # Logs a StageChange row and names it for this transaction, as Stages::ChangeThreshold does.
  def log_and_name(stage, field, old_value, new_value, name: true)
    change = StageChange.create!(stage:, field:, old_value:, new_value:, reason: "raw", changed_by_id: 1,
                                 changed_at: Time.current)
    sql("SELECT set_config('glassbox.stage_change_id', '#{change.id}', true)") if name
    change
  end

  def closed_stage
    stage = Stages::Open.call(stage: create_stage(threshold: 65, weight: 20))
    Stages::Close.call(stage:)
  end

  test "F-19: a closed stage's threshold cannot move even with its latest StageChange named" do
    stage = closed_stage
    refusal = raw_write do
      log_and_name(stage, "threshold", 65, 70)
      Stage.where(id: stage.id).update_all(threshold: 70)
    end
    assert refusal, "the database moved a closed stage's threshold"
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  test "F-19: a closed stage's weight cannot move even with its latest StageChange named" do
    stage = closed_stage
    refusal = raw_write do
      log_and_name(stage, "weight", 20, 30)
      Stage.where(id: stage.id).update_all(weight: 30)
    end
    assert refusal, "the database moved a closed stage's weight"
    assert_equal 20, stage.reload.weight
  end

  test "F-19/F-04 control: an OPEN stage's weight moves with its latest StageChange named" do
    stage = Stages::Open.call(stage: create_stage(weight: 20))
    assert_nil raw_write {
      log_and_name(stage, "weight", 20, 30)
      Stage.where(id: stage.id).update_all(weight: 30)
    }
    assert_equal 30, stage.reload.weight
  end

  test "F-20: the database refuses to close a stage whose participation is in review" do
    stage = Stages::Open.call(stage: create_stage(threshold: 60, review_below_threshold: true))
    p = create_participation(stage:)
    add_score(p, 55)
    decide!(p, outcome: "review", reason_code: "below_threshold_review")
    assert raw_write { Stage.where(id: stage.id).update_all(status: "closed") },
           "the database closed a stage with a candidate in review"
  end

  test "F-20: a superseded pass does not count as decided when the current decision is a review" do
    stage = Stages::Open.call(stage: create_stage(threshold: 60))
    p = create_participation(stage:)
    add_score(p, 70)
    pass = decide!(p, outcome: "pass")
    decide!(p, outcome: "review", basis: "manual", reason_code: "o", note: "cek ulang", supersedes: pass)
    assert raw_write { Stage.where(id: stage.id).update_all(status: "closed") },
           "the database counted a superseded pass and closed the stage"
  end

  test "F-20 control: the database closes a stage whose participants all have a current non-review decision" do
    stage = Stages::Open.call(stage: create_stage(threshold: 60))
    p = create_participation(stage:)
    add_score(p, 70)
    first = decide!(p, outcome: "review", basis: "manual", reason_code: "o", note: "n")
    decide!(p, outcome: "pass", basis: "manual", reason_code: "o", note: "n", supersedes: first)
    assert_nil raw_write { Stage.where(id: stage.id).update_all(status: "closed") }
  end

  test "F-21: an older weight StageChange cannot be named again to repeat its move" do
    stage = Stages::Open.call(stage: create_stage(weight: 20))
    older = log_and_name(stage, "weight", 20, 30, name: false)     # 20 -> 30, then superseded by
    log_and_name(stage, "weight", 30, 20, name: false)             # 30 -> 20: the stage sits at 20
    refusal = raw_write do
      sql("SELECT set_config('glassbox.stage_change_id', '#{older.id}', true)")
      Stage.where(id: stage.id).update_all(weight: 30)
    end
    assert refusal, "the older weight change was replayed"
    assert_equal 20, stage.reload.weight
  end

  test "F-04: a matching latest StageChange that this transaction did NOT name does not license the edit" do
    stage = Stages::Open.call(stage: create_stage(threshold: 65))
    refusal = raw_write do
      log_and_name(stage, "threshold", 65, 70, name: false)
      Stage.where(id: stage.id).update_all(threshold: 70)
    end
    assert refusal, "an unnamed StageChange licensed a raw threshold edit"
    assert_equal BigDecimal("65.0"), stage.reload.threshold
  end

  # A write that skips the model, inside a SAVEPOINT: a refusal rolls back only the savepoint,
  # so later reads in the test still work. Returns the refusal, or nil when the write was stored.
  def raw_write
    ActiveRecord::Base.transaction(requires_new: true) { yield }
    nil
  rescue ActiveRecord::StatementInvalid => e
    e
  end

  test "the model refuses to edit or destroy any of the three records" do
    [@entry, @decision, @change].each do |record|
      field = record.is_a?(StageChange) ? :reason : :reason_code
      field = :correction_reason if record.is_a?(ScoreEntry)
      assert_raises(ActiveRecord::ReadOnlyRecord, "#{record.class} update") { record.update!(field => "edited") }
      assert_raises(ActiveRecord::ReadOnlyRecord, "#{record.class} destroy") { record.destroy! }
    end
  end

  test "the database refuses a second decision superseding the same decision" do
    Decision.create!(participation: @p, outcome: "eliminate", basis: "manual", reason_code: "o", note: "n",
                     decided_by_id: 1, decided_at: Time.current, supersedes: @decision)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Decision.new(participation: @p, outcome: "review", basis: "manual", reason_code: "o", note: "n",
                   decided_by_id: 2, decided_at: Time.current, supersedes: @decision).save!(validate: false)
    end
  end

  test "the database refuses a correction without a reason" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ScoreEntry.new(participation: @p, value: 71, entered_by_id: 1, entered_at: Time.current, supersedes: @entry,
                     correction_reason: nil).save!(validate: false)
    end
  end

  test "the database refuses unknown outcome and basis values" do
    %w[outcome basis].each do |col|
      d = Decision.new(participation: create_participation(stage: @stage), outcome: "pass", basis: "threshold",
                       reason_code: "x", decided_at: Time.current)
      d[col] = "bogus"
      assert_raises(ActiveRecord::StatementInvalid, col) { d.save!(validate: false) }
    end
  end

  test "the database refuses a stage threshold above 100 or below 0, and weight out of range" do
    [{ threshold: BigDecimal("100.1") }, { threshold: BigDecimal("-0.1") }, { weight: 101 }, { weight: -1 }].each do |attrs|
      assert_raises(ActiveRecord::StatementInvalid, attrs.inspect) do
        ActiveRecord::Base.transaction(requires_new: true) { Stage.where(id: @stage.id).update_all(attrs) }
      end
    end
  end

  test "the database refuses a manual decision without an actor" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Decision.new(participation: create_participation(stage: @stage), outcome: "pass", basis: "manual",
                   reason_code: "o", note: "n", decided_by_id: nil, decided_at: Time.current).save!(validate: false)
    end
  end

  test "the database refuses a manual decision without a note" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Decision.new(participation: create_participation(stage: @stage), outcome: "pass", basis: "manual",
                   reason_code: "o", note: nil, decided_by_id: 1, decided_at: Time.current).save!(validate: false)
    end
  end

  test "the trigger function and all three triggers exist in the schema the tests run on" do
    names = sql("SELECT tgname FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgname").map { |r| r["tgname"] }
    assert_equal %w[decisions_append_only score_entries_append_only stage_changes_append_only], names & %w[
      decisions_append_only score_entries_append_only stage_changes_append_only]
  end
end
