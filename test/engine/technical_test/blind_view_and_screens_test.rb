require "test_helper"
require_relative "engine07_support"

# Test engine, feature 07 slices 1-2 on screen: the client-blind gate view (D62 h7: names hidden for
# owner and HR PIC until the gate decisions are confirmed), the candidate's own page after a gate
# close, the step-5 pages in every state and role, wording (house wording standard, 2026-10-08)
# and the house hard rules (no nested form, no disabled submit) on the rendered HTML.
class Engine07BlindViewAndScreensTest < ActionDispatch::IntegrationTest
  include Engine07Support

  NAMES = ["Bayu Ardiansyah E", "Citra Maharani E", "Dodi Firmansyah E"].freeze
  FORBIDDEN = /Terapkan|diterapkan|unggah|berkas|Tautan|Tatap muka/i

  def gate_with_people
    @job, @s1, @s2 = e7_gated_job
    e7_open_gate!(@s1)
    @rows = NAMES.map { |n| e7_applicant(@s1.reload, @s2.reload, name: n) }
    e7_scored!(@rows[0][0], 30, "eliminate")
    e7_scored!(@rows[1][0], 90, "pass")
    e7_scored!(@rows[1][1], 80, "pass")
  end

  def assert_house_rules(label)
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/i).size, doc.css("form").size, "nested form on #{label}"
    doc.css("form").each { |f| assert_empty f.css("form"), "form in form on #{label}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with], [data-turbo-submits-with]"),
                 "disabled submit on #{label}"
    refute_match(/fa-eye\b/, response.body, "view icon must be fa-plus on #{label}")
    text = doc.at("body").text
    assert_no_match FORBIDDEN, text, "wording standard on #{label}: #{text[FORBIDDEN]}"
  end

  # ---- blind view -----------------------------------------------------------------------------
  # Three roles (17 Oct 2026): only the superadmin sees names before the gate decision is confirmed;
  # the consultant is an hr_admin now and is as blind as the HR PIC.
  test "control: the superadmin sees the names in the gate box" do
    gate_with_people
    sign_in_as staff_user("admin")
    get staff_job_path(@job)
    box = css_select("#gerbang-seleksi").first.to_html
    NAMES.each { |n| assert_includes box, n }
    assert_house_rules("job show (superadmin)")
  end

  test "hr_admin (consultant, HR PIC) and hr_manager (owner): the gate box numbers candidates and never names them" do
    gate_with_people
    %w[consultant hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      box = css_select("#gerbang-seleksi").first.to_html
      assert_includes box, "Candidate 01"
      NAMES.each { |n| refute_includes box, n, "#{role} sees a name in the gate box" }
      assert_house_rules("job show (#{role})")
    end
  end

  # D62 h7: "Names hidden for owner and HR PIC too until the gate decisions are confirmed (also fixes
  # the earlier finding that the applicant table showed names at S1)". The gate box hides them; the
  # same page's applicant table prints them in full, beside the numbered gate rows.
  test "FINDING: HR PIC and owner see every candidate name elsewhere on the same Beranda Lowongan page" do
    gate_with_people
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      leaked = NAMES.select { |n| response.body.include?(n) }
      assert_empty leaked, "#{role} sees names on /staff/jobs/#{@job.id} outside the gate box: #{leaked.inspect}"
    end
  end

  test "FINDING: the gate box's own 'Lihat detail Kandidat 01' link opens a page titled with the name" do
    gate_with_people
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@job)
    link = css_select("#gerbang-seleksi tbody tr a").first
    get link["href"]
    assert_response :success
    leaked = NAMES.select { |n| response.body.include?(n) }
    assert_empty leaked, "HR PIC follows the numbered gate row and reads #{leaked.inspect}"
  end

  # ---- the candidate's own page after the gate closes -----------------------------------------
  test "the candidate's page after a gate close: no internal code, no score, no threshold" do
    gate_with_people
    e7_scored!(@rows[2][0], 85, "pass")
    e7_scored!(@rows[2][1], 75, "pass")
    Gates::Close.call(stage: @s1)
    application = @rows[0][0].job_application
    _link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
    get candidate_status_path(token)
    assert_response :success
    text = Nokogiri::HTML(response.body).at("body").text
    refute_includes text, "gate_eliminated"
    assert_no_match(/\bskor\b|\bambang\b|\bnilai \d/i, text, "score or threshold shown to the candidate")
    assert_no_match FORBIDDEN, text
  end

  # The S2 row of an S1-eliminated candidate must not fall through to CandidateStatus::DEFAULT_REASON
  # ("Hasil tahap ini belum memenuhi standar ...") for a test that was never scored.
  test "the candidate's S2 step after an S1 elimination is skipped, with no 'did not meet the standard' reason" do
    gate_with_people
    e7_scored!(@rows[2][0], 85, "pass")
    e7_scored!(@rows[2][1], 75, "pass")
    Gates::Close.call(stage: @s1)
    status = CandidateStatus.new(@rows[0][0].job_application.reload)
    test_step = status.steps.find { |s| s.participation&.stage_id == @s2.id }
    assert test_step, "no step for S2"
    assert_equal :skipped, test_step.state
    assert_nil test_step.reason, "S2 step reason for a never-scored test: #{test_step.reason.inspect}"
  end

  # ---- step 5 in every state and role ---------------------------------------------------------
  test "step 5 pages in every state, every staff role: house rules and wording" do
    job = e7_brief
    pages = []
    %w[consultant hr_pic owner reviewer admin].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_case_step_path(job)
      assert_response :success
      assert_house_rules("step5 empty #{role}")
      pages << response.body
    end
    e7_save(job)
    %w[consultant hr_pic].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_case_step_path(job)
      assert_house_rules("step5 draft #{role}")
      pages << response.body
    end
    TestCases::Approve.call(test_case: TechnicalTestCase.latest_for(job), actor: staff_user("hr_pic"))
    sign_in_as staff_user("consultant")
    get staff_job_test_case_step_path(job)
    assert_house_rules("step5 approved consultant (new-version form)")
    pages << response.body
    sign_in_as staff_user("consultant")
    post staff_job_test_cases_path(job), params: { test_case: e7_params(job, file: nil, weights: [50, 50]) }
    assert_response :unprocessable_content
    assert_house_rules("step5 refused v2 without reason")
    pages << response.body
  end

  # Maker-checker (load-bearing-tests rule 19): HR PIC approves what HR PIC reviewed. The approve
  # form carries only the version id; a draft is edited IN PLACE (B-2), so the consultant can change
  # the instructions, rubric or case file between HR's review and HR's click.
  # The job has its consultant assigned, so the HR PIC (also an hr_admin) is not the editor and is
  # shown the read-only version with the approve form (an editor is shown the edit form instead).
  test "FINDING: HR approves a draft the consultant changed after HR opened it (no fingerprint on the approve form)" do
    job = e7_brief
    job.update_columns(consultant_id: staff_user("consultant").id)
    e7_save(job, instructions: "Versi yang dibaca HR")
    sign_in_as staff_user("hr_pic")
    get staff_job_test_case_step_path(job)
    assert_includes response.body, "Versi yang dibaca HR"
    action = css_select("form.test-case-approve").first["action"]
    fields = css_select("form.test-case-approve input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    e7_save(job, instructions: "Diganti setelah HR membuka halaman", file: e7_upload(e7_xlsx([["Data lain"]]), "lain.xlsx"))
    post action, params: fields
    approved = TechnicalTestCase.current_for(job)
    if approved
      assert_equal "Versi yang dibaca HR", approved.instructions,
                   "HR PIC's click approved content HR never saw: #{approved.instructions.inspect}"
    end
  end

  # D60 clarification 16:45 names the stage "Tes teknis". The brief wizard that hosts step 5 still
  # labels S2 "Tes online" (Briefs::StagePlan::LABELS) in step 4 and the brief view; the candidate
  # page says "Tes kerja" (CandidateStatus::STAGE_LABELS). Record O-3 names only "Tes kerja".
  test "FINDING: the brief wizard that hosts step 5 'Technical test' calls the same stage 'Online test'" do
    job = e7_brief
    sign_in_as staff_user("consultant")
    seen = {}
    { "step 4" => staff_job_brief_step_path(job, 4), "step 5" => staff_job_test_case_step_path(job),
      "brief" => staff_job_brief_path(job) }.each do |label, path|
      get path
      assert_response :success
      text = Nokogiri::HTML(response.body).at("body").text
      # English names since A3 (16 Oct 2026); the Bahasa ones stay in the list so a reverted label is caught.
      seen[label] = ["Online test", "Work test", "Technical test", "Tes online", "Tes kerja", "Tes teknis"].select { |n| text.include?(n) }
    end
    assert seen.values.flatten.include?("Technical test"), "control: the wizard names the stage at all: #{seen.inspect}"
    off = seen.select { |_, names| names.any? { |n| n != "Technical test" } }
    assert_empty off, "S2 named otherwise inside the feature's wizard: #{seen.inspect}"
  end
end
