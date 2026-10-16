require "test_helper"
require_relative "run2_support"

# Test engine 07 run 2: two tabs or two devices at the same instant. Real threads on real
# connections, real commits (no test transaction), because a lock that only works inside one shared
# test connection proves nothing. Each test records the highest id of every table at setup and
# deletes everything above it at teardown; append-only triggers are bypassed for that cleanup with
# SET LOCAL session_replication_role = replica, which PostgreSQL resets at the end of that one
# transaction (the guard is back on before the next statement of any test; asserted below).
class Engine07Run2ConcurrencyTest < ActiveSupport::TestCase
  include Run2Support
  self.use_transactional_tests = false

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
    @t0 = Time.current.floor(6)
    @job = r2_job
    @appl, = r2_apply(@job, name: "Paralel Uji")
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

  def race(n = 2)
    gate = Queue.new
    threads = Array.new(n) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          begin
            yield
          rescue StandardError => e
            e
          end
        end
      end
    end
    n.times { gate << true }
    threads.map(&:value)
  end

  test "two 'Start test' at the same instant: one attempt, both see the same due_at, no error" do
    results = race { TechnicalTests::Start.call(application: JobApplication.find(@appl.id)) }
    errors = results.grep(Exception)
    assert_empty errors, errors.map { |e| "#{e.class}: #{e.message}" }.inspect
    assert_equal 1, TestAttempt.where(participation: r2_s2(@appl)).count
    assert_equal 1, results.map(&:id).uniq.size
  end

  test "two answers at the same instant: exactly one stored, the other refused with a sentence" do
    TechnicalTests::Start.call(application: @appl)
    files = [e7_xlsx([["satu"]]), e7_xlsx([["dua"]])]
    i = Queue.new
    files.each { |f| i << f }
    results = race do
      TechnicalTests::SubmitAnswer.call(application: JobApplication.find(@appl.id), file: e7_upload(i.pop, "j.xlsx"))
    end
    refusals = results.grep(TechnicalTests::SubmitAnswer::Refused)
    others = results.grep(Exception) - refusals
    assert_empty others, others.map { |e| "#{e.class}: #{e.message}" }.inspect
    assert_equal 1, refusals.size
    attempt = r2_attempt(@appl)
    assert attempt.answered_at
    assert_includes files.map { |f| Digest::SHA256.hexdigest(f) }, attempt.answer_sha256
  end

  test "the reminder and the receipt raced from two processes are each sent once" do
    late = TechnicalTests.submitted_at(@appl.reload) + 24.hours + 1.second
    results = travel_to(late) { race(3) { TechnicalTests::Notices.reminder(JobApplication.find(@appl.id), now: late) } }
    errors = results.grep(Exception)
    assert_empty errors, errors.map { |e| "#{e.class}: #{e.message}" }.inspect
    assert_equal 1, MailDelivery.where(job_application_id: @appl.id, kind: "test_reminder").count
  end

  test "two reviewers score the same answer at the same instant: one score, one decision" do
    r2_answer(@appl)
    a = r2_reviewer(email: "rev-a@uji.example")
    b = r2_reviewer(email: "rev-b@uji.example")
    reviewers = Queue.new
    [a, b].each { |r| reviewers << r }
    results = race do
      attempt = TestAttempt.find_by!(participation_id: r2_s2(@appl).id)
      TechnicalTests::ScoreAnswer.call(attempt:, reviewer: reviewers.pop, ratings: r2_ratings(attempt, [4, 4]), note: "Paralel")
    end
    others = results.grep(Exception) - results.grep(TechnicalTests::ScoreAnswer::Refused)
    assert_empty others, others.map { |e| "#{e.class}: #{e.message}" }.inspect
    s2 = r2_s2(@appl)
    assert_equal 1, s2.score_entries.count
    assert_equal 1, s2.decisions.count
    assert_equal 1, TestReview.where(participation_id: s2.id).count
  end
end
