require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03: D49 (5) "every change recorded". The audit table refuses UPDATE, DELETE
# and TRUNCATE in the database, one row is written per real change (none for an unchanged save or
# a refused one), and each row names the actor and the role they acted in.
class JobFormAuditTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  test "job_brief_changes is append-only in the database and in the model" do
    job = briefed_job
    row = job.brief_changes.first
    refused_by_database { JobBriefChange.where(id: row.id).update_all(actor_role: "owner") }
    refused_by_database { JobBriefChange.where(id: row.id).delete_all }
    refused_by_database { ActiveRecord::Base.connection.execute("TRUNCATE job_brief_changes CASCADE") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(actor_role: "owner") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
    assert_equal "hr_pic", row.reload.actor_role
    # Control: an INSERT is allowed, so the refusals above are about the operation, not the table.
    assert_difference -> { JobBriefChange.count }, 1 do
      JobBriefChange.create!(job:, actor: staff_user("consultant"), actor_role: "consultant", step: "1",
                             changes_made: { "title" => %w[a b] }, created_at: Time.current)
    end
  end

  test "one row per real change; an identical resave and a refused save write none" do
    job = briefed_job(complete: false)
    count = -> { job.brief_changes.count }
    { "1" => step1_params, "2" => step2_params, "3" => with_requirement_ids(job, step3_params), "4" => step4_params }.each do |step, params|
      assert_no_difference(count, "identical resave of step #{step}") { save_step!(job.reload, step, params) }
    end
    assert_no_difference(count, "refused save") { refute run_step(job.reload, "2", step2_params(shares: ["abc", 20, 20, 15, 15])).ok? }
    assert_difference(count, 1) { save_step!(job.reload, "1", step1_params(title: "Operator Mesin")) }
    row = job.brief_changes.order(:id).last
    assert_equal({ "title" => ["Operator Uji", "Operator Mesin"] }, row.changes_made)
    assert_difference(count, 1) { save_step!(job.reload, "2", step2_params(shares: [40, 20, 20, 10, 10])) }
    change = job.brief_changes.order(:id).last.changes_made
    assert_equal ["activities"], change.keys
    assert_equal [30, 40], change["activities"].map { |rows| rows.first["share_percent"] }
  end

  test "each row records the actor and the role; a consultant's completion is recorded as the consultant" do
    job = briefed_job(complete: false)
    consultant = staff_user("consultant")
    save_step!(job, "1", step1_params(title: "Diubah konsultan"), actor: consultant)
    assert Briefs::Complete.call(job: job.reload, actor: consultant).ok?
    rows = job.brief_changes.order(:id).last(2)
    assert_equal [["1", consultant.id, "consultant"], ["complete", consultant.id, "consultant"]],
                 rows.map { |r| [r.step, r.actor_id, r.actor_role] }
    first = job.brief_changes.order(:id).first
    assert_equal [staff_user("hr_pic").id, "hr_pic"], [first.actor_id, first.actor_role]
    assert_equal({ "brief_status" => %w[draft complete] }, rows.last.changes_made)
  end

  test "a knockout question edited before applications is recorded with its before and after" do
    job = briefed_job(complete: false)
    save_step!(job, "3", with_requirement_ids(job, step3_params(knockouts: ["Bersedia bekerja shift malam?", "Pengalaman minimal 1 tahun?"])))
    change = job.brief_changes.order(:id).last.changes_made
    before, after = change.fetch("requirements")
    assert_equal "Bersedia bekerja shift?", before.first["knockout"]
    assert_equal "Bersedia bekerja shift malam?", after.first["knockout"]
  end
end
