require "test_helper"
require_relative "engine07_support"

# Test engine, feature 07 slice 1: the gate "Seleksi CV dan Tes Teknis" (D60, plan §a, option A1).
# Service paths and immediate database guards. The deferred "together" guard is attacked for real
# (committed) in gate_commit_test.rb; here it is forced with SET CONSTRAINTS ... IMMEDIATE, which is
# the weaker form (it proves the trigger body, not that the commit runs it).
class Engine07GateAttackTest < ActiveSupport::TestCase
  include Engine07Support

  setup do
    @job, @s1, @s2 = e7_gated_job
    e7_open_gate!(@s1)
    @s1.reload
    @s2.reload
  end

  def immediate!
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS stages_gate_status_together IMMEDIATE")
  end

  # ---- open / close together ------------------------------------------------------------------
  test "opening S2 alone through Stages::Open opens the whole gate; opening it again is refused" do
    job, s1, s2 = e7_gated_job(title: "Uji buka S2")
    Stages::Open.call(stage: s2)
    assert_equal %w[open open], [s1.reload.status, s2.reload.status]
    assert_raises(ArgumentError) { Stages::Open.call(stage: s2) }
    assert_equal "draft", job.stages.find_by(code: "S5").status, "control: S5 is not a gate member"
  end

  test "Stages::Close refuses S1 and S2 alone, whatever the decisions; Gates::Close closes both" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 90, "pass")
    e7_scored!(a2, 90, "pass")
    [@s1, @s2].each { |stage| assert_raises(Stages::Close::GateRefused) { Stages::Close.call(stage:) } }
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
    Gates::Close.call(stage: @s2)
    assert_equal %w[closed closed], [@s1.reload.status, @s2.reload.status]
  end

  test "model update!(status: closed) on one member is refused by the model" do
    assert_raises(ActiveRecord::RecordInvalid) { @s1.update!(status: "closed") }
  end

  test "DB: closing one member alone by update_columns or raw SQL is refused (forced IMMEDIATE)" do
    error = refused_by_database do
      @s1.update_columns(status: "closed")
      immediate!
    end
    assert_match "must open and close together", error.message
    error = refused_by_database do
      ActiveRecord::Base.connection.execute("UPDATE stages SET status = 'closed' WHERE id = #{@s2.id}")
      immediate!
    end
    assert_match "must open and close together", error.message
    # control: both together in one statement passes the same forced check
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("UPDATE stages SET status = 'closed' WHERE id IN (#{@s1.id}, #{@s2.id})")
      immediate!
      raise ActiveRecord::Rollback
    end
  end

  test "DB: a closed gate cannot reopen one member; gate column cannot be dropped once open" do
    Gates::Close.call(stage: @s1)
    assert_match "status cannot move", refused_by_database { @s1.update_columns(status: "open") }.message
    assert_match "gate of a stage cannot change", refused_by_database { @s2.update_columns(gate: nil) }.message
  end

  test "DB: an open gate member cannot leave the gate, so its partner cannot be closed alone that way" do
    assert_match "gate of a stage cannot change", refused_by_database { @s2.update_columns(gate: nil) }.message
  end

  test "Gates::Close refuses while anyone is undecided or in review, and writes nothing" do
    pass1, pass2 = e7_applicant(@s1, @s2)
    out1, out2 = e7_applicant(@s1, @s2)
    e7_scored!(pass1, 90, "pass")          # S2 still undecided
    e7_scored!(out1, 10, "eliminate")
    before = Decision.count
    assert_raises(Stages::Close::Undecided) { Gates::Close.call(stage: @s1) }
    assert_equal before, Decision.count, "a refused close wrote a decision (gate_eliminated leaked)"
    assert_empty gate_rows(out2)
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
    e7_scored!(pass2, 70, "review")
    assert_raises(Stages::Close::Undecided) { Gates::Close.call(stage: @s1) }
    assert_equal before + 1, Decision.count
  end

  test "S1 in review blocks the close even when S2 is decided" do
    r1, r2 = e7_applicant(@s1, @s2)
    e7_scored!(r1, 55, "review")
    e7_scored!(r2, 90, "pass")
    assert_raises(Stages::Close::Undecided) { Gates::Close.call(stage: @s1) }
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
  end

  # ---- gate_eliminated -----------------------------------------------------------------------
  test "at close: S1-eliminated with S2 undecided gets exactly one gate row; S2 no-show keeps its own rule" do
    out1, out2 = e7_applicant(@s1, @s2)
    ns1, ns2 = e7_applicant(@s1, @s2)
    in1, in2 = e7_applicant(@s1, @s2)
    e7_scored!(out1, 20, "eliminate")
    e7_scored!(ns1, 20, "eliminate")
    ns2.update!(attendance: "no_show")
    e7_decide!(ns2, "eliminate", basis: "rule", reason: "no_show")
    e7_scored!(in1, 80, "pass")
    e7_scored!(in2, 80, "pass")
    assert_empty gate_rows(out2), "gate_eliminated written before close (B-1 says at close)"
    Gates::Close.call(stage: @s1)
    rows = gate_rows(out2).to_a
    assert_equal 1, rows.size
    assert_equal %w[eliminate rule], [rows.first.outcome, rows.first.basis]
    assert_empty out2.score_entries
    assert_equal "no_show", ns2.current_decision.reason_code, "no-show replaced by gate row"
    assert_empty gate_rows(ns2)
    assert_empty gate_rows(in2), "control: a passed S2 got a gate row"
    assert_equal :not_passed, Gates::Result.of(out1.current_decision, out2.current_decision)
    assert_equal :passed, Gates::Result.of(in1.current_decision, in2.current_decision)
  end

  test "no score may be entered on an S2 test closed by the gate (service-free, model path)" do
    out1, out2 = e7_applicant(@s1, @s2)
    e7_scored!(out1, 20, "eliminate")
    Gates::Close.call(stage: @s1)
    out2.update!(attendance: "attended")
    error = refused_by_database { e7_score!(out2, 99) }
    assert_match "closed by the gate", error.message
  end

  test "DB: gate_eliminated refused on S1, on an ungated S2, as manual/pass, after a score, with a superseded S1 elimination" do
    out1, out2 = e7_applicant(@s1, @s2)
    e7_scored!(out1, 20, "eliminate")
    p_s1_only, = e7_applicant(@s1, @s2)
    e7_scored!(p_s1_only, 10, "eliminate")
    assert_match "only on the S2 stage", refused_by_database {
      e7_decide!(p_s1_only, "eliminate", basis: "rule", reason: "gate_eliminated")
    }.message
    assert_match "decisions_gate_eliminated_is_rule", refused_by_database {
      e7_decide!(out2, "eliminate", basis: "manual", reason: "gate_eliminated", note: "paksa")
    }.message
    assert_match "decisions_gate_eliminated_is_rule", refused_by_database {
      e7_decide!(out2, "pass", basis: "rule", reason: "gate_eliminated")
    }.message
    # ungated S2 on another job
    plain = Job.create!(title: "Tanpa gerbang E7", golongan: 2, client_company: default_company)
    ps1 = plain.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60)
    ps2 = plain.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: 60)
    Stages::Open.call(stage: ps1)
    Stages::Open.call(stage: ps2)
    a = JobApplication.create!(job: plain)
    q1 = Participation.create!(job_application: a, stage: ps1, attendance: "attended")
    q2 = Participation.create!(job_application: a, stage: ps2, attendance: "pending")
    e7_scored!(q1, 5, "eliminate")
    assert_match "only on the S2 stage", refused_by_database {
      e7_decide!(q2, "eliminate", basis: "rule", reason: "gate_eliminated")
    }.message
    # after a score
    out2.update!(attendance: "attended")
    e7_score!(out2, 70)
    assert_match "nobody scored", refused_by_database {
      e7_decide!(out2, "eliminate", basis: "rule", reason: "gate_eliminated")
    }.message
    # superseded S1 elimination (reversal while open)
    r1, r2 = e7_applicant(@s1, @s2)
    e7_scored!(r1, 10, "eliminate")
    e7_decide!(r1, "pass", basis: "manual", reason: "reviewer_override", note: "CV dibaca ulang")
    assert_match "current S1 elimination", refused_by_database {
      e7_decide!(r2, "eliminate", basis: "rule", reason: "gate_eliminated")
    }.message
  end

  test "an S1 elimination reversed by a D37 threshold change while open gets no gate row at close" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 55, "eliminate")
    e7_scored!(a2, 80, "pass")
    Stages::ChangeThreshold.call(stage: @s1.reload, new_threshold: 50, reason: "Kalibrasi E7", actor_id: 1)
    assert_equal "pass", a1.reload.current_decision.outcome
    Gates::Close.call(stage: @s1)
    assert_empty gate_rows(a2)
    assert_equal :passed, Gates::Result.of(a1.current_decision, a2.current_decision)
  end

  test "mirror: a D37 raise turns an S1 pass into an elimination while open; close then writes the gate row" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 65, "pass")
    Stages::ChangeThreshold.call(stage: @s1.reload, new_threshold: 70, reason: "Ambang dinaikkan E7", actor_id: 1)
    assert_equal "eliminate", a1.reload.current_decision.outcome
    Gates::Close.call(stage: @s1)
    assert_equal 1, gate_rows(a2).count
  end

  test "D37 on S2 while open re-decides only threshold rows; rule rows and unscored S2 are untouched" do
    sc1, sc2 = e7_applicant(@s1, @s2)
    ns1, ns2 = e7_applicant(@s1, @s2)
    pend1, pend2 = e7_applicant(@s1, @s2)
    e7_scored!(sc1, 90, "pass")
    e7_scored!(sc2, 62, "pass")
    e7_scored!(ns1, 90, "pass")
    ns2.update!(attendance: "no_show")
    e7_decide!(ns2, "eliminate", basis: "rule", reason: "no_show")
    e7_scored!(pend1, 90, "pass")
    Stages::ChangeThreshold.call(stage: @s2.reload, new_threshold: 65, reason: "Naik E7", actor_id: 1)
    assert_equal "eliminate", sc2.reload.current_decision.outcome
    assert_equal "no_show", ns2.reload.current_decision.reason_code
    assert_nil pend2.reload.current_decision
  end

  test "D37: no threshold change on either member after the gate closes" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 80, "pass")
    e7_scored!(a2, 80, "pass")
    Gates::Close.call(stage: @s1)
    [@s1, @s2].each do |stage|
      assert_raises(ArgumentError) { Stages::ChangeThreshold.call(stage: stage.reload, new_threshold: 10, reason: "x", actor_id: 1) }
    end
  end

  # B-1 consequence: a manual S1 correction after close (the D37 E21 path) leaves the S2 gate row in
  # force with no S1 elimination behind it. Pinned as observed; reported as a finding under O-1.
  test "FINDING: an S1 correction after close leaves the candidate shut out of the test by a stale gate row" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 20, "eliminate")
    Gates::Close.call(stage: @s1)
    e7_decide!(a1.reload, "pass", basis: "manual", reason: "objection_upheld", note: "Keberatan diterima")
    assert_equal "pass", a1.reload.current_decision.outcome
    current_s2 = a2.reload.current_decision
    refute_equal "gate_eliminated", current_s2.reason_code,
                 "S1 was corrected to pass after close, but S2 still says 'Tidak dinilai: gugur di Seleksi CV' and the test can never be scored"
  end

  # The database accepts gate_eliminated at any moment while S1 is currently eliminated; "at close"
  # (B-1) lives only in Gates::Close. A second writer (slice 3/5) could write it early.
  test "FINDING: the database lets gate_eliminated be written while the gate is still open" do
    a1, a2 = e7_applicant(@s1, @s2)
    e7_scored!(a1, 20, "eliminate")
    error = nil
    begin
      ActiveRecord::Base.transaction(requires_new: true) { e7_decide!(a2, "eliminate", basis: "rule", reason: "gate_eliminated") }
    rescue ActiveRecord::StatementInvalid => e
      error = e
    end
    assert error, "gate_eliminated accepted on an OPEN gate; B-1 ('written at close, when S1 is final') is not held by the database"
  end

  # ---- Gates::Result --------------------------------------------------------------------------
  test "Gates::Result: all sixteen combinations" do
    d = ->(o) { o && Decision.new(outcome: o) }
    outcomes = [nil, "pass", "eliminate", "review"]
    outcomes.product(outcomes).each do |o1, o2|
      expected = if [o1, o2].include?("eliminate") then :not_passed
                 elsif [o1, o2] == %w[pass pass] then :passed
                 else :open
                 end
      assert_equal expected, Gates::Result.of(d.(o1), d.(o2)), "#{o1.inspect}/#{o2.inspect}"
    end
  end

  test "Gates::Open refuses a job whose gate has only S1, and the DB refuses opening it by hand" do
    job = Job.create!(title: "Gerbang setengah E7", golongan: 3, client_company: default_company)
    lone = job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60, gate: "screening")
    assert_raises(ArgumentError) { Gates::Open.call(stage: lone) }
    error = refused_by_database do
      lone.update_columns(status: "open", opened_at: Time.current)
      immediate!
    end
    assert_match "needs both S1 and S2", error.message
  end
end
