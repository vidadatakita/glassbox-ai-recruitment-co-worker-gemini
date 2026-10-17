require "test_helper"

# Independent test pass 2: two "Open portal" requests on the same vacancy at the same instant (two tabs, or
# two HR admins). Real threads on real connections and real commits, because a lock that only works
# inside one shared test connection proves nothing. The overlap is forced, not hoped for: a test-only
# barrier holds each thread just after Portal::WindowChange has run its checks (including "opened
# before?") until both threads have reached it, so both have passed the checks before either writes.
#
# Cleanup: the highest id of every table is recorded at setup and everything above it is deleted at
# teardown, with the append-only triggers bypassed by SET LOCAL session_replication_role = replica
# (reset by PostgreSQL at the end of that one transaction; asserted).
class CupPostingFlowRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Active only on threads that set :posting_race_barrier; every other caller runs the real code.
  module Barrier
    def check_preconditions!(closes_at)
      super
      barrier = Thread.current[:posting_race_barrier]
      return unless barrier

      barrier[:arrived] << Time.current
      barrier[:gate].pop(timeout: 10) || raise("barrier timeout: the other request never reached the checks")
    end
  end
  Portal::WindowChange.prepend(Barrier) unless Portal::WindowChange.ancestors.include?(Barrier)

  def conn = ActiveRecord::Base.connection

  def id_tables
    conn.select_values(<<~SQL)
      SELECT c.table_name FROM information_schema.columns c
      JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
      WHERE c.table_schema = 'public' AND c.column_name = 'id' AND t.table_type = 'BASE TABLE'
        AND c.data_type IN ('bigint', 'integer')
    SQL
  end

  setup do
    @marks = id_tables.to_h { |t| [t, conn.select_value("SELECT coalesce(max(id), 0) FROM #{conn.quote_table_name(t)}").to_i] }
    set_retention unless SystemSetting.retention_days
    publish_consent(at: 2.days.ago)
    @job = briefed_job(ad: false)
    @job.update_columns(ad_text: "About this role\nWe need a warehouse administrator in Bekasi.", ad_flags: [],
                        ad_approved_at: nil, ad_approved_by_id: nil)
    @a = staff_user("hr_pic")
    @b = staff_user("consultant")
  end

  teardown do
    conn.transaction do
      conn.execute("SET LOCAL session_replication_role = replica")
      @marks.each { |t, max| conn.execute("DELETE FROM #{conn.quote_table_name(t)} WHERE id > #{max}") }
    end
    assert_equal "origin", conn.select_value("SHOW session_replication_role"), "the guard was not restored"
    left = @marks.sum { |t, max| conn.select_value("SELECT count(*) FROM #{conn.quote_table_name(t)} WHERE id > #{max}").to_i }
    assert_equal 0, left, "residue rows left"
  end

  test "two opens at the same instant: one open event and one approval, the other request refused" do
    barrier = { arrived: Queue.new, gate: Queue.new }
    threads = [@a, @b].map do |actor|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:posting_race_barrier] = barrier
          Portal::WindowChange.open!(job: Job.find(@job.id), actor: User.find(actor.id))
        rescue StandardError => e
          e
        end
      end
    end
    arrivals = Array.new(2) { barrier[:arrived].pop(timeout: 10) }
    assert arrivals.all?, "only #{arrivals.compact.size} of 2 requests passed the checks: the race was not run"
    2.times { barrier[:gate] << true } # both passed "opened before?" before either wrote: overlap proven
    results = threads.map { |t| t.join(20)&.value }
    others = results.grep(Exception).reject { |e| e.is_a?(Portal::WindowChange::Refused) }
    assert_empty others, others.map { |e| "#{e.class}: #{e.message}" }.inspect

    opens = ApplicationWindowEvent.where(job_id: @job.id, action: "open").count
    approvals = JobBriefChange.where(job_id: @job.id, step: "ad").count { |c| c.changes_made.key?("ad_approved_at") }
    assert_equal 1, opens, "two open events for one vacancy: both requests reported 'Applicant portal opened.'"
    assert_equal 1, approvals
    # Run 3: the losing request is told why, and the winner is the named approver.
    refusals = results.grep(Portal::WindowChange::Refused)
    assert_equal 1, refusals.size, "exactly one request refused"
    assert_match(/opened before/, refusals.first.message)
    winner = results.find { |r| r.is_a?(ApplicationWindowEvent) }
    assert_equal winner.actor_id, Job.find(@job.id).ad_approved_by_id, "the approver is the request that opened"
  end
end
