require "test_helper"
require_relative "engine07_support"

# Test engine, feature 07 slice 2: the technical-test definition (D60, plan §c). Versions, the
# freeze once approved or started, the reason for a new version, time-limit bounds, rubric weights
# and anchors, the activity link, who approves, brief completion and the audit rows.
class Engine07TestDefinitionTest < ActiveSupport::TestCase
  include Engine07Support

  setup do
    @job = e7_brief
    @consultant = staff_user("consultant")
    @hr = staff_user("hr_pic")
  end

  def conn = ActiveRecord::Base.connection

  def ensure_stages!
    Briefs::Complete.call(job: @job.reload, actor: @hr) if @job.stages.none?
  end

  def start!(test_case)
    ensure_stages!
    application = JobApplication.create!(job: @job)
    s2 = @job.stages.find_by!(code: "S2")
    participation = Participation.create!(job_application: application, stage: s2, attendance: "pending")
    now = Time.current.change(usec: 0)
    TestAttempt.create!(participation:, test_case:, started_at: now, due_at: now + test_case.time_limit_minutes.minutes)
  end

  # ---- brief completion ------------------------------------------------------------------------
  test "package 3: completion refused with exactly one step-5 problem without a version, and with a draft" do
    result = Briefs::Complete.call(job: @job, actor: @hr)
    refute result.ok?
    assert_equal [5], result.problems.map(&:step), result.problems.map(&:message).inspect
    e7_save(@job)
    result = Briefs::Complete.call(job: @job.reload, actor: @hr)
    refute result.ok?, "a DRAFT version completed the brief"
    assert_equal [5], result.problems.map(&:step)
    TestCases::Approve.call(test_case: TechnicalTestCase.latest_for(@job), actor: @hr)
    assert Briefs::Complete.call(job: @job.reload, actor: @hr).ok?
  end

  test "package 2 completes with no test; packages 4 and 5 need one" do
    p2 = e7_brief(package: 2, golongan: 2)
    refute TestCases::Requirement.applies?(p2)
    assert Briefs::Complete.call(job: p2, actor: @hr).ok?
    [[4, 4], [5, 6]].each do |package, golongan|
      job = e7_brief(package:, golongan:)
      result = Briefs::Complete.call(job:, actor: @hr)
      refute result.ok?, "package #{package} completed without a test"
      assert_includes result.problems.map(&:step), 5
    end
  end

  test "factory judgement: briefed_job(test_case: false) really has no version; default really has an APPROVED one" do
    assert_nil TechnicalTestCase.latest_for(@job)
    job = briefed_job(golongan: 3, package: 3, complete: false)
    assert TechnicalTestCase.current_for(job)&.approved?, "factory default did not add an approved version"
    assert_nil TechnicalTestCase.latest_for(briefed_job(golongan: 2, package: 2, complete: false)), "package 2 got a test"
  end

  # ---- roles -----------------------------------------------------------------------------------
  test "only a consultant saves; a consultant not assigned to the job cannot; nothing is written on refusal" do
    other = staff_user("consultant", email: "konsultan-lain.e7@uji.example")
    @job.update_columns(consultant_id: @consultant.id)
    before = [TechnicalTestCase.count, JobBriefChange.count]
    (%w[hr_pic owner reviewer admin].map { |r| staff_user(r) } + [other]).each do |actor|
      result = e7_save(@job, actor:)
      refute result.ok?, "#{actor.role} #{actor.email_address} saved"
    end
    assert_equal before, [TechnicalTestCase.count, JobBriefChange.count]
    assert e7_save(@job, actor: @consultant).ok?, "control: the assigned consultant saves"
  end

  test "only HR PIC approves (service); consultant, owner, reviewer, admin refused" do
    tc = e7_save(@job).test_case
    %w[consultant owner reviewer admin].each do |role|
      refute TestCases::Approve.call(test_case: tc, actor: staff_user(role)).ok?, role
      refute tc.reload.approved?
    end
    assert TestCases::Approve.call(test_case: tc, actor: @hr).ok?
  end

  test "DB: approval by a non-HR user through update_columns is refused" do
    tc = e7_save(@job).test_case
    %w[consultant owner reviewer admin].each do |role|
      error = refused_by_database { tc.update_columns(approved_by_id: staff_user(role).id, approved_at: Time.current) }
      assert_match "only HR PIC approves", error.message
    end
  end

  # The approver-role and weight checks live in the UPDATE trigger only (test_cases_freeze is
  # BEFORE UPDATE OR DELETE). A version INSERTED already approved skips both.
  test "FINDING: the database accepts a version INSERTED already approved, by a consultant, with no rubric" do
    other = e7_save(@job).test_case # gives a recorded blob id to point at
    error = e7_sql_error(<<~SQL)
      INSERT INTO test_cases (job_id, version, instructions, time_limit_minutes, answer_types, new_version_reason,
                              case_file_blob_id, case_file_kind, scan_state, created_by_id, approved_by_id, approved_at,
                              created_at, updated_at)
      VALUES (#{@job.id}, 2, 'x', 35, ARRAY['xlsx']::varchar[], 'langsung', #{other.case_file_blob_id}, 'xlsx',
              'scan_unavailable', #{@consultant.id}, #{@consultant.id}, now(), now(), now())
    SQL
    forged = TechnicalTestCase.find_by(job: @job, version: 2)
    consequence = forged && TechnicalTestCase.current_for(@job)&.id == forged.id && TestCases::Requirement.problems(@job).empty? &&
                  forged.criteria.none?
    assert error, "an approved version with approver=consultant and 0 criteria was INSERTED " \
                  "(observed: it is the version in force and step 5 reports no problem = #{consequence.inspect})"
  end

  # Same hole from Ruby: no model validation on approver role or rubric total.
  test "FINDING: TechnicalTestCase.create! with approved_by a consultant is accepted by model and database" do
    draft = e7_save(@job).test_case
    forged = nil
    begin
      ActiveRecord::Base.transaction(requires_new: true) do
        forged = TechnicalTestCase.create!(job: @job, version: 2, instructions: "x", answer_types: %w[xlsx], new_version_reason: "r",
                                           case_file_blob_id: draft.case_file_blob_id, case_file_kind: "xlsx",
                                           scan_state: "scan_unavailable", created_by: @consultant,
                                           approved_by: @consultant, approved_at: Time.current)
      end
    rescue ActiveRecord::ActiveRecordError
      forged = nil
    end
    assert_nil forged, "create! accepted an approval by #{forged&.approved_by&.role} with #{forged&.criteria&.size} criteria"
  end

  # ---- time limit ------------------------------------------------------------------------------
  test "time limit bounds through the service: 1, 34, 35, 60 accepted; 0, 61, -5, 35.5, text refused" do
    { "1" => 1, "34" => 34, "35" => 35, "60" => 60, " 60 " => 60 }.each do |typed, stored|
      result = e7_save(@job, time_limit_minutes: typed)
      assert result.ok?, "#{typed.inspect}: #{result.errors.inspect}"
      assert_equal stored, result.test_case.reload.time_limit_minutes
    end
    %w[0 61 -5 35.5 tigapuluh 99999999999].each do |typed|
      before = TechnicalTestCase.latest_for(@job).time_limit_minutes
      result = e7_save(@job, time_limit_minutes: typed)
      refute result.ok?, "#{typed.inspect} accepted"
      assert_equal before, TechnicalTestCase.latest_for(@job).reload.time_limit_minutes
    end
  end

  test "a blank time limit on a new version means the default 35, not 0" do
    result = e7_save(@job, time_limit_minutes: "")
    assert result.ok?, result.errors.inspect
    assert_equal 35, result.test_case.time_limit_minutes
  end

  test "DB: time limit 0, 61 and NULL refused by the table; 1 and 60 accepted" do
    tc = e7_save(@job).test_case
    [0, 61, "NULL"].each do |v|
      assert e7_sql_error("UPDATE test_cases SET time_limit_minutes = #{v} WHERE id = #{tc.id}"), "#{v} accepted"
    end
    [1, 60].each { |v| assert_nil e7_sql_error("UPDATE test_cases SET time_limit_minutes = #{v} WHERE id = #{tc.id}") }
  end

  # ---- rubric ----------------------------------------------------------------------------------
  test "weights: 0 and 101 per row refused at save; 99 and 101 totals refused at approval; 100 approves" do
    %w[0 101].each do |w|
      result = e7_save(@job, weights: [w, 50])
      refute result.ok?, "weight #{w} saved"
    end
    [[49, 50], [51, 50]].each do |weights|
      tc = e7_save(@job, weights:).test_case
      result = TestCases::Approve.call(test_case: tc.reload, actor: @hr)
      refute result.ok?, "#{weights.sum}% approved"
      assert(result.errors.any? { |e| e.include?("#{weights.sum}%") }, result.errors.inspect)
    end
    tc = e7_save(@job, weights: [60, 40]).test_case
    assert TestCases::Approve.call(test_case: tc.reload, actor: @hr).ok?
  end

  test "DB: approval of a 99% rubric by update_columns is refused" do
    tc = e7_save(@job, weights: [49, 50]).test_case
    assert_match "sum to 100", refused_by_database { tc.update_columns(approved_by_id: @hr.id, approved_at: Time.current) }.message
  end

  test "1/3/5 anchors are each required; a criterion with one blank anchor is refused" do
    %i[anchor_1 anchor_3 anchor_5].each do |anchor|
      params = e7_params(@job)
      params[:criteria]["0"][anchor] = "  "
      result = TestCases::SaveVersion.call(job: @job, actor: @consultant, params:)
      refute result.ok?, "blank #{anchor} saved"
    end
  end

  test "a criterion linked to ANOTHER job's activity is refused at save" do
    other = e7_brief(package: 3, golongan: 3)
    foreign = other.activities.first.id
    result = e7_save(@job, activity_ids: [foreign])
    refute result.ok?, "another job's activity accepted"
    assert_nil TechnicalTestCase.latest_for(@job)
  end

  test "a criterion forced onto another job's activity is refused at approval (Readiness)" do
    tc = e7_save(@job).test_case
    foreign = e7_brief(package: 3, golongan: 3).activities.first
    tc.criteria.first.update_columns(activity_id: foreign.id)
    refute TestCases::Approve.call(test_case: tc.reload, actor: @hr).ok?
  end

  # Briefs::SaveStep for step 2 deletes and re-creates activity rows when the form carries no ids.
  # The APPROVED version keeps criteria pointing at deleted activities and the brief still completes.
  test "FINDING: after a step-2 edit the approved test's rubric links no activity of this job, and the brief still completes" do
    tc = e7_approved!(@job)
    save_step!(@job.reload, "2", step2_params(shares: [40, 20, 20, 10, 10]))
    live = @job.reload.activities.pluck(:id)
    assert Briefs::Complete.call(job: @job, actor: @hr).ok?
    linked = tc.criteria.reload.map(&:activity_id)
    assert_empty linked - live, "approved rubric criteria #{linked.inspect} point at activities no longer in the brief #{live.inspect}"
  end

  # ---- versions and freeze ---------------------------------------------------------------------
  test "a draft edits in place (no new version); after approval a save makes v2 only with a reason" do
    v1 = e7_save(@job).test_case
    e7_save(@job, instructions: "Teks diubah sebelum disetujui")
    assert_equal [1], TechnicalTestCase.where(job: @job).pluck(:version)
    assert_equal "Teks diubah sebelum disetujui", v1.reload.instructions
    TestCases::Approve.call(test_case: v1, actor: @hr)
    refute e7_save(@job, instructions: "tanpa alasan").ok?
    refute e7_save(@job, instructions: "spasi", new_version_reason: "   ").ok?, "whitespace reason accepted"
    assert_equal [1], TechnicalTestCase.where(job: @job).pluck(:version)
    v2 = e7_save(@job, instructions: "Versi baru", new_version_reason: "Data kasus diperbarui").test_case
    assert_equal 2, v2.version
    assert_equal "Teks diubah sebelum disetujui", v1.reload.instructions, "v1 changed"
    assert_equal v1.id, TechnicalTestCase.current_for(@job).id, "an unapproved v2 replaced the approved v1"
  end

  test "DB: whitespace reason on v2 refused by CHECK" do
    e7_approved!(@job)
    error = e7_sql_error(<<~SQL)
      INSERT INTO test_cases (job_id, version, new_version_reason, created_by_id, created_at, updated_at)
      VALUES (#{@job.id}, 2, '   ', #{@consultant.id}, now(), now())
    SQL
    assert_match "test_cases_new_version_has_reason", error&.message.to_s
  end

  test "approved version: rubric, file, time limit, instructions refused by update_columns, raw SQL and delete" do
    tc = e7_approved!(@job)
    { "time_limit_minutes = 60" => "approved and final", "instructions = 'diganti'" => "approved and final",
      "approved_at = NULL, approved_by_id = NULL" => "approved and final",
      "case_file_blob_id = case_file_blob_id + 1" => "approved and final" }.each do |set, msg|
      assert_match msg, e7_sql_error("UPDATE test_cases SET #{set} WHERE id = #{tc.id}")&.message.to_s, set
    end
    assert_match "approved and final", refused_by_database { tc.update_columns(time_limit_minutes: 50) }.message
    crit = tc.criteria.first
    assert_match "never changes", e7_sql_error("UPDATE test_case_criteria SET weight = 1 WHERE id = #{crit.id}")&.message.to_s
    assert_match "never changes", e7_sql_error("DELETE FROM test_case_criteria WHERE id = #{crit.id}")&.message.to_s
    assert_match "never changes", e7_sql_error(<<~SQL)&.message.to_s
      INSERT INTO test_case_criteria (test_case_id, position, activity_text, name, weight, anchor_1, anchor_3, anchor_5, created_at, updated_at)
      VALUES (#{tc.id}, 9, 'a', 'b', 5, '1', '3', '5', now(), now())
    SQL
    assert_match "never deleted", e7_sql_error("DELETE FROM test_cases WHERE id = #{tc.id}")&.message.to_s
    att = tc.case_file.attachment
    assert_match "never changes", e7_sql_error("DELETE FROM active_storage_attachments WHERE id = #{att.id}")&.message.to_s
    assert_match "never changes", e7_sql_error("UPDATE active_storage_attachments SET blob_id = blob_id WHERE id = #{att.id}")&.message.to_s
    assert e7_sql_error("TRUNCATE test_cases CASCADE"), "TRUNCATE accepted"
  end

  test "approved version through the service: a save never touches v1, it makes v2" do
    tc = e7_approved!(@job)
    before = tc.attributes.except("updated_at")
    crit = tc.criteria.map(&:attributes)
    result = e7_save(@job, time_limit_minutes: "60", weights: [70, 30], new_version_reason: "Waktu diperpanjang")
    assert result.ok?, result.errors.inspect
    assert_equal before, tc.reload.attributes.except("updated_at")
    assert_equal crit, tc.criteria.reload.map(&:attributes)
  end

  test "started version: frozen with the 'started' message even when only a draft; attempt guards" do
    tc = e7_approved!(@job)
    attempt = start!(tc)
    assert_match "started by a candidate", e7_sql_error("UPDATE test_cases SET time_limit_minutes = 10 WHERE id = #{tc.id}")&.message.to_s
    assert_match "never change", e7_sql_error("UPDATE test_attempts SET due_at = due_at + interval '1 hour' WHERE id = #{attempt.id}")&.message.to_s
    assert_match "never deleted", e7_sql_error("DELETE FROM test_attempts WHERE id = #{attempt.id}")&.message.to_s
    # an attempt on a draft version, on another job's version, outside S2
    draft = e7_save(@job, new_version_reason: "draft v2").test_case
    assert_match "only an approved", e7_sql_error(attempt_sql(draft.id))&.message.to_s
    other = e7_brief(package: 3, golongan: 3)
    other_tc = e7_approved!(other)
    assert_match "another job", e7_sql_error(attempt_sql(other_tc.id))&.message.to_s
  end

  def attempt_sql(test_case_id)
    ensure_stages!
    application = JobApplication.create!(job: @job)
    s2 = @job.stages.find_by!(code: "S2")
    p = Participation.create!(job_application: application, stage: s2, attendance: "pending")
    "INSERT INTO test_attempts (participation_id, test_case_id, started_at, due_at, created_at, updated_at) " \
      "VALUES (#{p.id}, #{test_case_id}, now(), now() + interval '35 minutes', now(), now())"
  end

  # ---- audit -----------------------------------------------------------------------------------
  test "audit: each save with a change and each approval is one step-5 row with actor and role; an unchanged save none" do
    count = -> { JobBriefChange.where(job: @job, step: "5").count }
    assert_difference(count, 1) { e7_save(@job) }
    tc = TechnicalTestCase.latest_for(@job)
    assert_no_difference(count) { TestCases::SaveVersion.call(job: @job, actor: @consultant, params: e7_params(@job, file: nil)) }
    assert_difference(count, 1) { e7_save(@job, file: nil, instructions: "Berubah") }
    assert_difference(count, 1) { TestCases::Approve.call(test_case: tc, actor: @hr) }
    rows = JobBriefChange.where(job: @job, step: "5").order(:id).to_a
    assert_equal %w[consultant consultant hr_pic], rows.map(&:actor_role)
    assert_equal [@consultant.id, @consultant.id, @hr.id], rows.map(&:actor_id)
    assert_equal [false, true], rows.last.changes_made["approved"]
    assert_no_difference(count) { TestCases::Approve.call(test_case: tc, actor: staff_user("owner")) }
  end

  test "a replaced file on a draft is recorded by its SHA-256 in the audit row" do
    e7_save(@job)
    other = e7_xlsx([["Lain"], [1]])
    e7_save(@job, file: e7_upload(other, "kasus-e7.xlsx"))
    row = JobBriefChange.where(job: @job, step: "5").order(:id).last
    assert_equal Digest::SHA256.hexdigest(other), row.changes_made["case_file_sha256"].last
  end
end
