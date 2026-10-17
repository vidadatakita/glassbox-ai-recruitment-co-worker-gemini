require "test_helper"

class Briefs::SaveStepTest < ActiveSupport::TestCase
  test "every saved change writes an audit row with who, role, step and before/after; an unchanged save writes none" do
    job = briefed_job(complete: false)
    consultant = staff_user("consultant")
    before = job.brief_changes.count
    save_step!(job, "1", step1_params(title: "Operator Mesin Uji"), actor: consultant)
    change = job.brief_changes.order(:id).last
    assert_equal before + 1, job.brief_changes.count
    assert_equal [consultant.id, "hr_admin", "1"], [change.actor_id, change.actor_role, change.step]
    assert_equal ["Operator Uji", "Operator Mesin Uji"], change.changes_made["title"]
    save_step!(job, "1", step1_params(title: "Operator Mesin Uji"), actor: consultant)
    assert_equal before + 1, job.brief_changes.count, "an unchanged save is not a change"
  end

  test "the audit row is append-only in the database" do
    job = briefed_job(complete: false)
    error = refused_by_database { JobBriefChange.where(job:).update_all(step: "2") }
    assert_match(/append-only/, error.message)
  end

  test "a malformed number is refused, never read as zero" do
    job = briefed_job(complete: false)
    params = step2_params
    params[:activities]["0"][:share_percent] = "tiga puluh"
    result = Briefs::SaveStep.call(job:, step: "2", params:, actor: staff_user("hr_pic"))
    refute result.ok?
    assert(result.errors.any? { |e| e.include?("Activity 1: time share must be a whole number") })
    assert_equal 30, job.activities.reload.first.share_percent, "nothing saved"
  end

  test "a forged row id from another job cannot edit that job" do
    other = briefed_job(complete: false)
    job = briefed_job(complete: false)
    params = step2_params
    params[:activities]["0"][:id] = other.activities.first.id.to_s
    assert_raises(ActiveRecord::RecordNotFound) { Briefs::SaveStep.call(job:, step: "2", params:, actor: staff_user("hr_pic")) }
    assert_equal "Aktivitas uji 1", other.activities.reload.first.description
  end

  test "rule 3: once a stage has opened, requirements, Golongan and step 4 are refused" do
    job = briefed_job
    Stages::Open.call(stage: job.stages.find_by!(code: "S1"))
    hr = staff_user("hr_pic")
    r3 = Briefs::SaveStep.call(job:, step: "3", params: step3_params(weights: [50, 50]), actor: hr)
    refute r3.ok?
    assert(r3.errors.first.include?("locked"))
    r4 = Briefs::SaveStep.call(job:, step: "4", params: step4_params, actor: hr)
    refute r4.ok?
    r1 = Briefs::SaveStep.call(job:, step: "1", params: step1_params(golongan: 4), actor: hr)
    refute r1.ok?
    assert_equal 2, job.reload.golongan
    # control: the parts that do not drive scoring stay editable
    salary = step3_params.except(:requirements).merge(salary_max: "6.500.000")
    assert Briefs::SaveStep.call(job:, step: "3", params: salary, actor: hr).ok?
    assert_equal 6_500_000, job.reload.salary_max
  end

  test "knockout questions are frozen once an application exists, and edited in place before that" do
    job = briefed_job
    question = job.knockout_questions.order(:position).first
    save_step!(job, "3", with_requirement_ids(job, step3_params(knockouts: ["Bersedia bekerja shift malam?", "Pengalaman minimal 1 tahun?"])))
    assert_equal "Bersedia bekerja shift malam?", question.reload.text, "same id kept: Lamar answers are keyed by it"
    JobApplication.create!(job:)
    result = Briefs::SaveStep.call(job:, step: "3", params: with_requirement_ids(job, step3_params(knockouts: ["Pertanyaan baru?", "Pengalaman minimal 1 tahun?"])),
                                   actor: staff_user("hr_pic"))
    refute result.ok?
    assert_equal "Bersedia bekerja shift malam?", question.reload.text
  end

  test "a knockout question is only accepted on a wajib requirement (rule 16)" do
    job = briefed_job(complete: false)
    params = step3_params
    params[:requirements]["3"][:knockout] = "Pertanyaan pada syarat sebaiknya?"
    result = Briefs::SaveStep.call(job:, step: "3", params:, actor: staff_user("hr_pic"))
    refute result.ok?
    assert(result.errors.any? { |e| e.include?("only for a must-have requirement") })
  end

  test "a complete brief stays complete: a save that breaks it is refused whole" do
    job = briefed_job
    result = Briefs::SaveStep.call(job:, step: "2", params: step2_params(shares: [30, 20, 20, 15, 10]), actor: staff_user("hr_pic"))
    refute result.ok?
    # 17 Oct 2026: each line names its step (the gaps are often in other steps than the one saved).
    assert_includes result.errors, "Step 2 (Activities & 90-day target): The activity time shares add up to 95%; they must add up to exactly 100%."
    assert_equal 15, job.activities.reload.last.share_percent
    assert job.reload.brief_complete?
  end

  test "salary accepts the house rupiah form and refuses decimals; location is derived from placements" do
    job = briefed_job(complete: false)
    save_step!(job, "3", step3_params.merge(salary_min: "Rp5.200.000"))
    assert_equal 5_200_000, job.reload.salary_min
    assert_equal "Bekasi, Karawang", job.location
    result = Briefs::SaveStep.call(job:, step: "3", params: step3_params.merge(salary_min: "5.200.000,50"), actor: staff_user("hr_pic"))
    refute result.ok?
  end
end
