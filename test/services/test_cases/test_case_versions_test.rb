require "test_helper"

# D60 slice 2 (plan §c): versioned test definition, consultant edits, HR PIC approves, the brief
# needs an approved version, a started version is frozen, a new version needs a reason, every
# change is an audit row. Guards are tested at the service AND the database, each with a control.
class TestCases::TestCaseVersionsTest < ActiveSupport::TestCase
  # Three roles (17 Oct 2026): both people are HR Admins. The assigned consultant (a person,
  # jobs.consultant_id) edits; the HR Admin role (and the superadmin) approves.
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @consultant = staff_user("consultant")
    @hr = staff_user("hr_pic")
  end

  def save(params = case_version_params(@job), actor: @consultant) = TestCases::SaveVersion.call(job: @job, actor:, params:)

  # --- the brief check -------------------------------------------------------------------------

  test "a package-3 brief cannot complete without an approved test version, and can with one" do
    result = Briefs::Complete.call(job: @job, actor: @hr)
    refute result.ok?
    assert_equal [5], result.problems.map(&:step).uniq
    assert_match(/technical test has not been created/, result.problems.first.message)
    draft = save.test_case
    assert_match(/version 1 has not been approved by HR/, Briefs::Complete.call(job: @job, actor: @hr).problems.first.message)
    assert TestCases::Approve.call(test_case: draft, actor: @hr).ok?
    assert Briefs::Complete.call(job: @job.reload, actor: @hr).ok?
  end

  test "control: a package-2 brief needs no test version" do
    job = briefed_job(golongan: 2, package: 2, complete: false, test_case: false)
    refute TestCases::Requirement.applies?(job)
    assert Briefs::Complete.call(job:, actor: @hr).ok?
  end

  # --- who -----------------------------------------------------------------------------------

  test "only an HR Admin saves and approves, never the HR Manager; once assigned, only the assigned consultant saves" do
    %w[owner reviewer].each do |role|
      refute save(actor: staff_user(role)).ok?, "#{role} saved a test version"
    end
    draft = save.test_case
    %w[owner reviewer].each do |role|
      refute TestCases::Approve.call(test_case: draft, actor: staff_user(role)).ok?, "#{role} approved"
    end
    other = staff_user("consultant", email: "konsultan.lain@uji.example")
    @job.update!(consultant: @consultant)
    refute save(actor: other).ok?, "an HR Admin not assigned to the job saved"
    refute save(actor: @hr).ok?, "the HR Admin who is not the assigned consultant saved"
    refute save(actor: staff_user("admin")).ok?, "the superadmin is not the assigned consultant either"
    assert save.ok?, "control: the assigned consultant saves"
    assert TestCases::Approve.call(test_case: TechnicalTestCase.latest_for(@job), actor: @hr).ok?, "control: the HR Admin approves"
  end

  test "the database refuses an approval by the HR Manager" do
    draft = save.test_case
    error = refused_by_database { draft.update_columns(approved_by_id: staff_user("reviewer").id, approved_at: Time.current) }
    assert_match(/only HR PIC approves/, error.message)
  end

  # --- what a version holds ------------------------------------------------------------------

  test "a saved draft keeps the file, instructions, limit, answer types and rubric linked to activities" do
    result = save
    assert result.ok?, result.errors.inspect
    tc = result.test_case.reload
    assert_equal [1, 35, %w[xlsx], "xlsx", "scan_unavailable"], [tc.version, tc.time_limit_minutes, tc.answer_types, tc.case_file_kind, tc.scan_state]
    assert tc.case_file.attached?
    assert_equal tc.case_file.blob_id, tc.case_file_blob_id
    assert_equal [60, 40], tc.criteria.map(&:weight)
    assert_equal @job.activities.first.description, tc.criteria.first.activity_text
    assert_equal @consultant, tc.created_by
  end

  test "time limit: default 35, 60 accepted, 61 and text refused" do
    assert_equal 35, TechnicalTestCase.new.time_limit_minutes
    ok = save(case_version_params(@job).merge(time_limit_minutes: "60"))
    assert ok.ok?
    assert_equal 60, ok.test_case.reload.time_limit_minutes
    refute save(case_version_params(@job).merge(time_limit_minutes: "61")).ok?
    refute save(case_version_params(@job).merge(time_limit_minutes: "tiga puluh")).ok?
    error = refused_by_database { ok.test_case.update_columns(time_limit_minutes: 61) }
    assert_match(/test_cases_time_limit_max_60/, error.message)
  end

  test "a dangerous case file is refused and nothing is saved" do
    require "zip"
    bad = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("[Content_Types].xml"); zip.write("<Types/>")
      zip.put_next_entry("xl/workbook.xml"); zip.write("<workbook/>")
      zip.put_next_entry("xl/vbaProject.bin"); zip.write("VBA")
    end.string
    result = save(case_version_params(@job, file: upload(bad, "kasus.xlsx")))
    refute result.ok?
    assert_match(/Case study file: .*macro/, result.errors.first)
    assert_equal 0, TechnicalTestCase.where(job: @job).count
  end

  test "approval needs a complete version: weights 100, a file, an answer type, instructions" do
    draft = save(case_version_params(@job, weights: [60, 30])).test_case
    result = TestCases::Approve.call(test_case: draft, actor: @hr)
    refute result.ok?
    assert_includes result.errors, "The criterion weights add up to 90%; they must total exactly 100%."
    error = refused_by_database { draft.update_columns(approved_by_id: @hr.id, approved_at: Time.current) }
    assert_match(/weights must sum to 100/, error.message)
  end

  test "an infected scan refuses the upload" do
    adapter = Object.new
    def adapter.call(_io) = "infected"
    TestCases::FileScan.adapter = adapter
    result = save
    refute result.ok?
    assert_match(/antivirus detected/, result.errors.join)
  ensure
    TestCases::FileScan.adapter = TestCases::FileScan::Unavailable.new
  end

  # --- versions and freeze -------------------------------------------------------------------

  test "a draft is edited in place; after approval a save makes version 2 and needs a reason" do
    first = save.test_case
    assert_equal first.id, save(case_version_params(@job).merge(instructions: "Petunjuk baru")).test_case.id
    TestCases::Approve.call(test_case: first.reload, actor: @hr)
    no_reason = save(case_version_params(@job).merge(instructions: "Petunjuk versi dua"))
    refute no_reason.ok?
    assert_match(/reason for the new version is required/, no_reason.errors.first)
    second = save(case_version_params(@job).merge(instructions: "Petunjuk versi dua", new_version_reason: "Kasus diperjelas"))
    assert second.ok?, second.errors.inspect
    assert_equal 2, second.test_case.version
    assert_equal "Petunjuk baru", first.reload.instructions, "version 1 did not change"
    assert_equal first, TechnicalTestCase.current_for(@job), "version 1 stays in force until version 2 is approved"
  end

  test "the database refuses a version 2 without a reason" do
    save
    error = refused_by_database do
      TechnicalTestCase.create!(job: @job, version: 2, created_by: @consultant, instructions: "x")
    end
    assert_match(/test_cases_new_version_has_reason/, error.message)
  end

  test "an approved version, its rubric and its case file never change in the database" do
    tc = save.test_case
    TestCases::Approve.call(test_case: tc, actor: @hr)
    assert_match(/approved and final/, refused_by_database { tc.update_columns(instructions: "diubah") }.message)
    assert_match(/rubric of a started or approved/, refused_by_database { tc.criteria.first.update_columns(weight: 99) }.message)
    assert_match(/case file of a started or approved/, refused_by_database { tc.case_file.attachment.delete }.message)
    assert_match(/never deleted/, refused_by_database { TechnicalTestCase.where(id: tc.id).delete_all }.message)
  end

  test "control: a draft's rubric and case file can still change" do
    tc = save.test_case
    tc.criteria.first.update_columns(weight: 55)
    assert_equal 55, tc.criteria.first.reload.weight
    replaced = save(case_version_params(@job, file: upload(xlsx_bytes([["Lain"]]), "kasus2.xlsx")))
    assert replaced.ok?, replaced.errors.inspect
    assert_equal replaced.test_case.reload.case_file.blob_id, replaced.test_case.case_file_blob_id
  end

  test "a started version is frozen, checked before the approval rule" do
    tc = approved_version
    start!(tc)
    error = refused_by_database { tc.update_columns(instructions: "diubah") }
    assert_match(/has been started by a candidate and is frozen/, error.message)
    assert_match(/rubric of a started/, refused_by_database { tc.criteria.first.destroy! }.message)
    assert tc.reload.started?
  end

  test "an attempt starts only on an approved version of its own job, on S2, and is never moved or deleted" do
    draft = save.test_case
    s2 = s2_participation
    assert_match(/only an approved test version/, refused_by_database { TestAttempt.create!(participation: s2, test_case: draft, started_at: (t = Time.current.floor(6)), due_at: t + 35.minutes) }.message)
    TestCases::Approve.call(test_case: draft, actor: @hr)
    s1 = Participation.create!(job_application: s2.job_application, stage: stage("S1"), attendance: "pending")
    assert_match(/not the technical test/, refused_by_database { TestAttempt.create!(participation: s1, test_case: draft, started_at: (t = Time.current.floor(6)), due_at: t + 35.minutes) }.message)
    attempt = TestAttempt.create!(participation: s2, test_case: draft, started_at: (t = Time.current.floor(6)), due_at: t + 35.minutes)
    assert_match(/never change/, refused_by_database { attempt.update_columns(due_at: 2.hours.from_now) }.message)
    assert_match(/never deleted/, refused_by_database { attempt.delete }.message)
  end

  test "F-03: a version cannot be created already approved (model and database)" do
    draft = save.test_case
    forged = TechnicalTestCase.new(job: @job, version: 2, instructions: "x", answer_types: %w[xlsx], new_version_reason: "r",
                                   case_file_blob_id: draft.case_file_blob_id, created_by: @consultant, approved_by: @hr, approved_at: Time.current)
    refute forged.valid?
    error = refused_by_database { forged.save!(validate: false) }
    assert_match(/inserted as a draft/, error.message)
  end

  test "F-05: a step-2 save without row ids keeps activity ids, so the approved rubric still links them" do
    tc = approved_version
    linked = tc.criteria.map(&:activity_id)
    save_step!(@job.reload, "2", step2_params(shares: [40, 20, 20, 10, 10]))
    assert_empty linked - @job.reload.activities.pluck(:id)
    assert_empty TestCases::Requirement.problems(@job)
  end

  test "F-05: an activity really removed leaves the version in force orphaned, and the brief says so" do
    tc = approved_version
    removed = tc.criteria.first.activity_id
    rows = @job.activities.reject { |a| a.id == removed }.each_with_index.to_h do |a, i|
      [i.to_s, { id: a.id.to_s, description: a.description, output: a.output, share_percent: (i.zero? ? a.share_percent + 30 : a.share_percent).to_s }]
    end
    Briefs::SaveStep.call(job: @job.reload, step: "2", params: { success_90d: @job.success_90d, activities: rows }, actor: @hr)
    assert_equal ["The technical test rubric refers to a deleted activity; create a new version."], TestCases::Requirement.problems(@job.reload)
  end

  # --- audit ---------------------------------------------------------------------------------

  test "every save and the approval write an audit row with actor, role and before/after; an unchanged save writes none" do
    params = case_version_params(@job)
    tc = save(params).test_case
    row = @job.brief_changes.where(step: "5").order(:id).last
    assert_equal [@consultant.id, "hr_admin"], [row.actor_id, row.actor_role]
    assert_equal [nil, 1], row.changes_made["test_case_version"]
    count = @job.brief_changes.count
    save(params.except(:case_file))
    assert_equal count, @job.brief_changes.count, "an unchanged save recorded a change"
    save(params.except(:case_file).merge(instructions: "Diganti"))
    assert_equal ["Periksa lembar stok, temukan selisih, lalu tulis koreksinya.", "Diganti"],
                 @job.brief_changes.order(:id).last.changes_made["instructions"]
    TestCases::Approve.call(test_case: tc.reload, actor: @hr)
    assert_equal [false, true], @job.brief_changes.order(:id).last.changes_made["approved"]
  end

  private

  def approved_version
    tc = save.test_case
    assert TestCases::Approve.call(test_case: tc, actor: @hr).ok?
    tc.reload
  end

  # The brief is not complete in these tests, so its stages are made here, ungated and draft.
  def stage(code)
    @job.stages.find_by(code:) || @job.stages.create!(code:, score_source: code == "S1" ? "ai" : "manual_or_import", weight: 25, threshold: 60)
  end

  def s2_participation
    Participation.create!(job_application: JobApplication.create!(job: @job), stage: stage("S2"), attendance: "pending")
  end

  def start!(tc) = TestAttempt.create!(participation: s2_participation, test_case: tc, started_at: (t = Time.current.floor(6)), due_at: t + 35.minutes)
end
