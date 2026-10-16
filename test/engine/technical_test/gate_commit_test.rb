require "test_helper"

# Test engine, feature 07 slice 1: the deferred guard stages_gate_status_together fires only at
# COMMIT. A transactional test never commits, so these tests run with real commits (no test
# transaction) and clean up their own rows (stages and jobs only; no append-only table is touched,
# no client company is created, so nothing outlives the test). Marker: job title "E7-COMMIT".
class Engine07GateCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @job = Job.create!(title: "E7-COMMIT gerbang", golongan: 3, client_company: default_company)
    @s1 = @job.stages.create!(code: "S1", score_source: "ai", weight: 10, threshold: 60, gate: "screening")
    @s2 = @job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 20, threshold: 60, gate: "screening")
  end

  teardown do
    conn = ActiveRecord::Base.connection
    ids = conn.select_values("SELECT id FROM jobs WHERE title LIKE 'E7-COMMIT%'")
    unless ids.empty?
      conn.execute("DELETE FROM stages WHERE job_id IN (#{ids.join(',')})")
      conn.execute("DELETE FROM jobs WHERE id IN (#{ids.join(',')})")
    end
    assert_equal 0, conn.select_value("SELECT count(*) FROM jobs WHERE title LIKE 'E7-COMMIT%'").to_i, "residue left"
  end

  def statuses = Stage.where(id: [@s1.id, @s2.id]).order(:code).pluck(:status)

  test "COMMIT: opening S1 alone by update_columns (autocommit) is refused; nothing changes" do
    assert_raises(ActiveRecord::StatementInvalid) { @s1.update_columns(status: "open", opened_at: Time.current) }
    assert_equal %w[draft draft], statuses
  end

  test "COMMIT: opening S2 alone by raw SQL inside an explicit transaction is refused at commit" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("UPDATE stages SET status = 'open', opened_at = now() WHERE id = #{@s2.id}")
      end
    end
    assert_match "must open and close together", error.message
    assert_equal %w[draft draft], statuses
  end

  test "COMMIT: closing one member alone after both opened is refused, even with SET CONSTRAINTS DEFERRED" do
    Gates::Open.call(stage: @s1)
    assert_equal %w[open open], statuses, "control: Gates::Open opens both and commits"
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL DEFERRED")
        @s2.update_columns(status: "closed")
      end
    end
    assert_equal %w[open open], statuses
    assert_raises(ActiveRecord::StatementInvalid) { @s1.update_columns(status: "closed") }
    assert_equal %w[open open], statuses
    # control: both together commit
    Gates::Close.call(stage: @s1)
    assert_equal %w[closed closed], statuses
  end

  test "COMMIT: dropping the gate from both drafts is accepted, after which S1 opens alone (package not tied to the gate in the database)" do
    # Probe of a DB gap: nothing in the database ties package 3+ to the gate column. Stated, not
    # asserted as a defect here; reported as a low finding with the business consequence.
    ActiveRecord::Base.connection.execute("UPDATE stages SET gate = NULL WHERE id IN (#{@s1.id}, #{@s2.id})")
    @s1.reload.update_columns(status: "open", opened_at: Time.current)
    assert_equal %w[open draft], statuses
  end
end
