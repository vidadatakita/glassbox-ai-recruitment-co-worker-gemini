require "test_helper"

# D60 slice 1: S1 (Seleksi CV) and S2 (Tes teknis) as one gate "Seleksi CV dan Tes Teknis".
# The online-test plan §a; decision D60 (GlassBox Team 16:28/16:32,
# clarifications 16:45). Each guard has its control beside it (load-bearing-tests rule 5).
class Gates::GateTest < ActiveSupport::TestCase
  include GateFactory

  setup { @job, @s1, @s2 = gated_job }

  # --- opening ---------------------------------------------------------------------------------

  test "opening either stage of the gate opens both, at the same moment" do
    now = Time.zone.local(2026, 10, 12, 9, 0)
    Stages::Open.call(stage: @s2, now:)
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
    assert_equal [now, now], [@s1.opened_at, @s2.opened_at]
    assert_equal "draft", @job.stages.find_by!(code: "S5").status, "control: a stage outside the gate stays a draft"
  end

  test "a stage without a gate still opens alone (control: the scoring core is unchanged)" do
    plain = create_stage(code: "S3")
    partner = create_stage(code: "S5", job: plain.job)
    Stages::Open.call(stage: plain)
    assert_equal %w[open draft], [plain.reload.status, partner.reload.status]
  end

  test "the gate does not open when one stage is no longer a draft" do
    Stages::Open.call(stage: @s1)
    error = assert_raises(ArgumentError) { Gates::Open.call(stage: @s1) }
    assert_includes error.message, "drafts"
  end

  # --- closing: service guard ------------------------------------------------------------------

  test "Stages::Close refuses a gate stage on its own, and nothing closes" do
    open_gate!
    assert_raises(Stages::Close::GateRefused) { Stages::Close.call(stage: @s1) }
    assert_raises(Stages::Close::GateRefused) { Stages::Close.call(stage: @s2) }
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
  end

  test "control: Stages::Close still closes a stage without a gate" do
    plain = create_open_stage(code: "S3")
    assert_equal "closed", Stages::Close.call(stage: plain).status
  end

  test "Gates::Close closes both stages together when everyone is decided" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 80, "pass")
    p2.update!(attendance: "attended")
    scored_decision!(p2, 75, "pass")
    Gates::Close.call(stage: @s2)
    assert_equal %w[closed closed], [@s1.reload.status, @s2.reload.status]
    assert_equal :passed, Gates::Result.of(p1.current_decision, p2.current_decision)
  end

  # --- closing: database guard -----------------------------------------------------------------

  test "the database refuses closing one gate stage alone, bypassing every service" do
    open_gate!
    error = refused_by_database do
      @s1.update_columns(status: "closed")
      Gates::Constraint.check_now!
    end
    assert_match(/must open and close together/, error.message)
    assert_equal "open", @s1.reload.status
  end

  test "control: the database accepts both gate stages closed in one transaction" do
    open_gate!
    ActiveRecord::Base.transaction(requires_new: true) do
      @s1.update_columns(status: "closed")
      @s2.update_columns(status: "closed")
      Gates::Constraint.check_now!
    end
    assert_equal %w[closed closed], [@s1.reload.status, @s2.reload.status]
  end

  test "the database refuses opening one gate stage alone" do
    error = refused_by_database do
      @s1.update_columns(status: "open", opened_at: Time.current)
      Gates::Constraint.check_now!
    end
    assert_match(/must open and close together/, error.message)
  end

  test "the database refuses an opened gate that lacks its S2" do
    job = Job.create!(title: "Gerbang tidak lengkap", golongan: 3, client_company: default_company)
    lone = job.stages.create!(code: "S1", score_source: "ai", weight: 100, threshold: 60, gate: "screening")
    error = refused_by_database do
      lone.update_columns(status: "open", opened_at: Time.current)
      Gates::Constraint.check_now!
    end
    assert_match(/needs both S1 and S2/, error.message)
  end

  test "the gate of a stage cannot change after it opened, and only S1/S2 can carry one" do
    open_gate!
    error = refused_by_database { @s2.update_columns(gate: nil) }
    assert_match(/gate of a stage cannot change/, error.message)
    s3 = @job.stages.create!(code: "S3", score_source: "scorecard", weight: 0, threshold: 60)
    error = refused_by_database { s3.update_columns(gate: "screening") }
    assert_match(/stages_gate/, error.message)
  end

  # --- S1 eliminated -> S2 gate_eliminated ----------------------------------------------------

  test "closing the gate writes gate_eliminated on S2 for every S1 elimination, with no score" do
    open_gate!
    out1, out2 = gate_applicant(@s1, @s2)
    in1, in2 = gate_applicant(@s1, @s2)
    scored_decision!(out1, 40, "eliminate")
    scored_decision!(in1, 85, "pass")
    in2.update!(attendance: "attended")
    scored_decision!(in2, 70, "pass")
    Gates::Close.call(stage: @s1, now: Time.zone.local(2026, 10, 20, 17, 0))

    decision = out2.current_decision
    assert_equal %w[eliminate rule gate_eliminated], [decision.outcome, decision.basis, decision.reason_code]
    assert_empty out2.score_entries, "a gate elimination carries no score"
    assert_equal "pass", in2.current_decision.outcome, "control: a candidate who passed S1 keeps the S2 decision"
    assert_equal :not_passed, Gates::Result.of(out1.current_decision, decision)
  end

  test "a refused gate close writes nothing, not even the gate eliminations" do
    open_gate!
    out1, out2 = gate_applicant(@s1, @s2)
    wait1, = gate_applicant(@s1, @s2)
    scored_decision!(out1, 40, "eliminate")
    scored_decision!(wait1, 90, "pass") # its S2 test is not decided yet
    assert_raises(Stages::Close::Undecided) { Gates::Close.call(stage: @s1) }
    assert_nil out2.reload.current_decision
    assert_equal %w[open open], [@s1.reload.status, @s2.reload.status]
  end

  test "an S1 elimination reversed before close leaves S2 open for the test (why the row is written at close)" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 55, "eliminate")
    Stages::ChangeThreshold.call(stage: @s1, new_threshold: 50, reason: "Ambang terlalu tinggi", actor_id: ACTOR_ID)
    assert_equal "pass", p1.current_decision.outcome
    assert_raises(Stages::Close::Undecided) { Gates::Close.call(stage: @s1) }
    assert_nil p2.reload.current_decision, "no gate_eliminated for a candidate who is back in"
  end

  test "an S2 no-show is a rule elimination (rule 5) and fails the gate" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 80, "pass")
    p2.update!(attendance: "no_show")
    result = Scoring::Decider.decide(score: nil, threshold: @s2.threshold, attendance: :no_show)
    no_show = Decision.create!(participation: p2, outcome: result.outcome.to_s, basis: result.basis.to_s,
                               reason_code: result.reason_code, decided_at: Time.current)
    assert_equal %w[eliminate rule no_show], [no_show.outcome, no_show.basis, no_show.reason_code]
    assert_equal :not_passed, Gates::Result.of(p1.current_decision, no_show)
  end

  # --- database guards on gate_eliminated -------------------------------------------------------

  test "the database refuses gate_eliminated when the S1 decision is not an elimination" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 80, "pass")
    error = refused_by_database { gate_row(p2) }
    assert_match(/needs a current S1 elimination/, error.message)
  end

  test "the database refuses gate_eliminated once the S1 elimination was superseded" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    first = scored_decision!(p1, 40, "eliminate")
    decide!(p1, outcome: "pass", basis: "manual", reason_code: "override", note: "Bukti baru", supersedes: first)
    error = refused_by_database { gate_row(p2) }
    assert_match(/needs a current S1 elimination/, error.message)
  end

  test "control: the database accepts gate_eliminated on a gated S2 after a current S1 elimination" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 40, "eliminate")
    assert gate_row(p2).persisted?
  end

  test "the database refuses gate_eliminated outside a gate, on S1, as a manual decision, or after a score" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 40, "eliminate")
    assert_match(/only on the S2 stage of a gate/, refused_by_database { gate_row(p1) }.message)
    plain = create_open_stage(code: "S2", source: "manual_or_import")
    assert_match(/only on the S2 stage of a gate/, refused_by_database { gate_row(create_participation(stage: plain)) }.message)
    manual = refused_by_database do
      Decision.new(participation: p2, outcome: "eliminate", basis: "manual", reason_code: "gate_eliminated", note: "x",
                   decided_by_id: ACTOR_ID, decided_at: Time.current).save!(validate: false)
    end
    assert_match(/decisions_gate_eliminated_is_rule/, manual.message)
    p2.update!(attendance: "attended")
    add_score(p2, 50)
    assert_match(/for a test nobody scored/, refused_by_database { gate_row(p2) }.message)
  end

  test "F-06: the database refuses gate_eliminated while the gate is not closing" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 40, "eliminate")
    error = refused_by_database { gate_row(p2, closing: false) }
    assert_match(/only while the gate closes/, error.message)
    assert gate_row(p2).persisted?, "control: accepted while Gates::Close names this S2 stage"
  end

  test "F-04: an S1 elimination corrected after close reopens the S2 test for review, by the same person" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    first = scored_decision!(p1, 40, "eliminate")
    Gates::Close.call(stage: @s1)
    assert_equal "gate_eliminated", p2.reload.current_decision.reason_code
    decide!(p1, outcome: "pass", basis: "manual", reason_code: "objection_upheld", note: "Keberatan diterima", supersedes: first)
    reopened = p2.reload.current_decision
    assert_equal %w[review manual gate_reopened_after_s1_correction], [reopened.outcome, reopened.basis, reopened.reason_code]
    assert_equal ACTOR_ID, reopened.decided_by_id
    assert reopened.note.present?
    other1, other2 = gate_applicant(@s1, @s2)
    assert_nil other2.reload.current_decision, "control: nobody else is touched"
  end

  test "F-04 control: an S1 correction that stays an elimination leaves the gate row" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    first = scored_decision!(p1, 40, "eliminate")
    Gates::Close.call(stage: @s1)
    decide!(p1, outcome: "eliminate", basis: "manual", reason_code: "objection_rejected", note: "Keberatan ditolak", supersedes: first)
    assert_equal "gate_eliminated", p2.reload.current_decision.reason_code
  end

  test "no score can be entered on an S2 test closed by the gate" do
    open_gate!
    p1, p2 = gate_applicant(@s1, @s2)
    scored_decision!(p1, 40, "eliminate")
    gate_row(p2)
    p2.update_columns(attendance: "attended")
    error = refused_by_database { add_score(p2, 90) }
    assert_match(/never scored/, error.message)
    other1, other2 = gate_applicant(@s1, @s2)
    scored_decision!(other1, 90, "pass")
    other2.update!(attendance: "attended")
    assert add_score(other2, 90).persisted?, "control: a test in the gate can be scored"
  end

  private

  def open_gate!
    Gates::Open.call(stage: @s1)
    @s1.reload
    @s2.reload
  end

  # Straight to the database (model validations skipped): these tests are about the trigger.
  # closing: names the S2 stage the way Gates::Close does (F-06); false leaves the gate "open".
  def gate_row(participation, closing: true)
    s2_id = closing ? @s2.id.to_s : ""
    ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT set_config('glassbox.gate_closing', ?, true)", s2_id]))
    row = Decision.new(participation:, outcome: "eliminate", basis: "rule", reason_code: "gate_eliminated", decided_at: Time.current)
    row.save!(validate: false)
    row
  end
end
