require "test_helper"

# Feature 03, the job form "New vacancy": role matrix (D49 (5)), the wizard through the real
# routes, the house form rules on every step, rule 3 on screen, grouped multi-value display, and the
# ad-approval gate (task part D).
class JobFormTest < ActionDispatch::IntegrationTest
  setup { Rails.cache.clear }

  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form on #{request.path}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
  end

  def form_params(hash) = { brief: hash }

  test "with the technical test in the package, step 4 leads on to step 5 and the brief is completed there" do
    job = briefed_job(package: 3, complete: false, test_case: false) # package 3 runs S2: step 5 exists
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    assert_select "button[name=lanjut]", text: /Save & next/
    assert_select "button[name=finish]", 0, "no completion before the last step"

    patch staff_job_brief_step_path(job, 4), params: form_params(step4_params(package: 3)).merge(lanjut: "1")
    assert_redirected_to staff_job_test_case_step_path(job)
    get staff_job_test_case_step_path(job)
    assert_select "form[action=?] button", staff_job_brief_complete_path(job), text: /Complete brief/i

    post staff_job_brief_complete_path(job)
    assert_redirected_to staff_job_brief_path(job)
    refute job.reload.brief_complete?, "no approved test version yet: refused, the brief page lists why"
    approved_test_case!(job)
    post staff_job_brief_complete_path(job)
    assert job.reload.brief_complete?
  end

  test "without the technical test, step 4 is the last step and completes the brief" do
    job = briefed_job(package: 2, complete: false) # package 2: S1 and S5, no step 5
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    assert_select "button[name=finish]", text: /complete brief/
    assert_select "button[name=lanjut]", 0
  end

  test "job ad: written and checked on its page, a rule flag saved only with a reason, then shown on Lamar once the portal opens" do
    job = briefed_job(complete: true)
    job.update_columns(ad_approved_at: nil, ad_approved_by_id: nil)
    sign_in_as staff_user("hr_pic")
    Screening::Config.stub(:enabled?, false) do
      post staff_job_ad_path(job), params: { ad_text: "Tentang posisi ini\n- Pria, usia maksimal 30 tahun" }
      assert_response :unprocessable_content, "a sentence that names a protected attribute needs a written reason at save"
      assert_select "textarea[name=flags_reason][required]"
      post staff_job_ad_path(job), params: { ad_text: "Tentang posisi ini\n- Pria, usia maksimal 30 tahun", flags_reason: "Uji: alasan tertulis." }
    end
    assert_redirected_to staff_job_path(job, anchor: "applicant-portal")
    assert_equal ["age, gender", "Uji: alasan tertulis."], job.brief_changes.where(step: "ad").last.changes_made["ad_flags_reason"]
    fake = Struct.new(:text) { def generate(**) = Screening::AiClient::Reply.new(model: "uji", text:, input_tokens: 1, output_tokens: 1) }.new({ ad_text: "Versi AI." }.to_json)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake) { post staff_job_ad_path(job), params: { ai: "1", ad_text: "draf", instruksi: "lebih singkat" } }
    end
    suggestion = job.brief_suggestions.last
    assert_redirected_to staff_job_ad_path(job, saran: suggestion.id, anchor: "hasil-ai"), "the AI button posts to the same address (per-form CSRF), and lands on the result"
    fake2 = Struct.new(:text) { def generate(**) = Screening::AiClient::Reply.new(model: "uji", text:, input_tokens: 1, output_tokens: 1) }.new({ ad_text: "Versi AI kedua." }.to_json)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake2) { post staff_job_ad_path(job), params: { ai: "1", ad_text: "draf", instruksi: "" }, as: :json }
    end
    assert_equal({ "ad_text" => "Versi AI kedua." }, JSON.parse(response.body)["fields"], "from the page script: the text, no reload")
    assert_equal "Versi AI.", suggestion.ad_text
    # 17 Oct 2026: no separate approval step. Opening the portal approves the ad, under the opener's name.
    assert_nil job.reload.ad_approved_at, "the ad is not live before the portal opens"
    open_portal(job)
    assert job.reload.ad_approved_at, "opening the portal approved the ad"
    get lamar_path(job.public_code)
    assert_includes response.body, "About this vacancy"
  end

  # Three-role model (17 Oct 2026): owner and reviewer are both HR managers. Superadmin passes every
  # role check, so it is no longer in the refused list; the allowed side is asserted below.
  test "HR managers cannot create or edit a brief, but can read it; superadmin may open the form" do
    job = briefed_job(complete: false)
    %w[owner reviewer].each do |role|
      sign_in_as staff_user(role)
      get staff_new_job_path
      assert_redirected_to staff_jobs_path, "#{role} new"
      assert_no_difference -> { Job.count } do
        post staff_create_job_path, params: form_params(step1_params)
      end
      patch staff_job_brief_step_path(job, 1), params: form_params(step1_params(title: "Diubah #{role}"))
      assert_equal "Operator Uji", job.reload.title, "#{role} edited the brief"
      get staff_job_brief_path(job)
      assert_response :success, "#{role} reads the brief"
      assert_select "a[href=?]", staff_job_brief_step_path(job, 1), 0
      sign_out
    end
    sign_in_as staff_user("superadmin")
    get staff_new_job_path
    assert_response :success, "superadmin passes every role check"
  end

  # hr_pic and consultant are two HR admin persons since the three-role model, so every change
  # records the role "hr_admin".
  test "both HR admin persons write a brief end to end; every save is recorded" do
    { "hr_pic" => "Operator HR", "consultant" => "Operator Konsultan" }.each do |role, title|
      sign_in_as staff_user(role)
      post staff_create_job_path, params: form_params(step1_params(title:))
      job = Job.order(:id).last
      assert_equal title, job.title
      assert_equal ClientCompany.first, job.client_company
      assert_redirected_to staff_job_brief_step_path(job, 2)
      patch staff_job_brief_step_path(job, 2), params: form_params(step2_params)
      assert_redirected_to staff_job_brief_step_path(job, 3)
      patch staff_job_brief_step_path(job, 3), params: form_params(step3_params)
      patch staff_job_brief_step_path(job, 4), params: form_params(step4_params).merge(commit: "Simpan")
      refute job.reload.brief_complete?, "Save alone keeps a draft"
      # D60 slice 2: package 3 runs S2, so step 5 (consultant uploads, HR PIC approves) comes first.
      approved_test_case!(job)
      patch staff_job_brief_step_path(job, 4), params: form_params(step4_params).merge(finish: "1", commit: "Simpan & selesaikan brief")
      assert_redirected_to staff_job_brief_path(job)
      assert job.reload.brief_complete?
      assert_equal %w[1 2 3 4 5 5 complete], job.brief_changes.order(:id).pluck(:step)
      assert_equal ["hr_admin"], job.brief_changes.where.not(step: "5").pluck(:actor_role).uniq
      # Step 5 is still two different persons: one HR admin uploads the case, another approves it.
      assert_equal [staff_user("consultant").id, staff_user("hr_pic").id], job.brief_changes.where(step: "5").order(:id).pluck(:actor_id)
      assert_equal %w[hr_admin hr_admin], job.brief_changes.where(step: "5").order(:id).pluck(:actor_role)
      sign_out
    end
  end

  test "each step renders for both editors and keeps the house form rules" do
    job = briefed_job(complete: false)
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_new_job_path
      assert_response :success
      assert_house_form_rules
      (1..4).each do |step|
        get staff_job_brief_step_path(job, step)
        assert_response :success, "#{role} step #{step}"
        assert_house_form_rules
        # One commit button per step: "Save & next" on steps 1-3, "Save" on step 4 (the value follows the label).
        assert_select "form[data-submit-guard] button[name=commit]", 1
        assert_select "form[data-submit-guard] button[name=commit][value=?]", (step == 4 ? "Save" : "Save & next"), 1
      end
      get staff_job_brief_path(job)
      assert_house_form_rules
      sign_out
    end
  end

  test "step 4 offers the named finish button; a refused completion keeps the draft and lists what is missing" do
    # Package 2 has no technical test, so step 4 is the last step (with S2 it leads on to step 5).
    job = briefed_job(package: 2, complete: false)
    job.activities.first.update!(share_percent: 10)
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    assert_select "button[name=finish][value='1']", 1
    patch staff_job_brief_step_path(job, 4), params: form_params(step4_params(package: 2)).merge(finish: "1")
    assert_response :unprocessable_content
    assert_includes response.body, "The activity time shares add up to 80%; they must add up to exactly 100%."
    refute job.reload.brief_complete?
  end

  test "a refused save keeps what was typed" do
    job = briefed_job(complete: false)
    sign_in_as staff_user("hr_pic")
    params = step2_params
    params[:activities]["1"][:share_percent] = "dua puluh"
    params[:activities]["0"][:description] = "Teks yang baru diketik"
    patch staff_job_brief_step_path(job, 2), params: form_params(params)
    assert_response :unprocessable_content
    assert_select "input[name='brief[activities][0][description]'][value=?]", "Teks yang baru diketik"
    assert_select "input[name='brief[activities][1][share_percent]'][value=?]", "dua puluh"
  end

  test "rule 3 on screen: after a stage opens, step 3 shows requirements read-only and step 4 has no form" do
    job = briefed_job
    Stages::Open.call(stage: job.stages.find_by!(code: "S1"))
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 3)
    assert_includes response.body, "The scoring parts are locked."
    assert_select "input[name^='brief[requirements]']", 0
    assert_select "input[name='brief[salary_min]']", 1, "control: the salary stays editable"
    get staff_job_brief_step_path(job, 4)
    assert_select "form.job-brief-form", 0
    assert_select "input[name^='brief[']", 0
    assert_includes response.body, "The scoring parts are locked."
  end

  test "multi-value fields render as separately grouped lists with their counts and empty states" do
    job = briefed_job
    job.requirements.where(tier: "nilai_tambah").destroy_all
    sign_in_as staff_user("owner")
    get staff_job_brief_path(job)
    assert_select ".job-brief-chips li", 2
    assert_includes response.body, "Placement <span class=\"text-muted fw-normal\">· 2 locations</span>"
    assert_includes response.body, "No nice-to-have requirement yet."
    assert_select "h4.job-brief-group-title", text: /Must-have · 3 requirements/
    refute_includes response.body, "Bekasi, Karawang", "never a comma-joined multi-value on a staff screen"
  end

  test "a draft brief: the vacancy page says the portal waits for the brief, and offers no approval step" do
    job = briefed_job(complete: false)
    job.update!(client_company: company, ad_text: "Tentang posisi ini\nIklan uji.")
    sign_in_as staff_user("hr_pic")
    get staff_job_path(job)
    assert_match(/The applicant portal opens once the vacancy brief is complete|All brief steps are filled in/, response.body)
    assert_select "a.portal-missing__fix", minimum: 1
    assert_no_match(/Approve job ad/, response.body, "the approval step is taken down")
    assert_select "a[title='View vacancy brief details'] i.fa-plus"
  end

  test "an ad without a text: the box says to write it first, and the portal refuses to open" do
    job = briefed_job(ad: false)
    sign_in_as staff_user("hr_pic")
    get staff_job_path(job)
    assert_includes response.body, "The job ad has not been written yet."
    set_retention
    publish_consent
    error = assert_raises(Portal::WindowChange::Refused) { Portal::WindowChange.open!(job:, actor: staff_user("hr_pic")) }
    assert_match(/job ad has not been written yet/, error.message)
  end

  test "saving a draft ad goes straight to the portal card; opening the portal approves the ad under the opener's name" do
    job = briefed_job(ad: false)
    set_retention
    publish_consent
    hr = staff_user("hr_pic")
    sign_in_as hr
    post staff_job_ad_path(job), params: { ad_text: "About this role\nWe need an accounting supervisor." }
    assert_redirected_to staff_job_path(job, anchor: "applicant-portal")
    assert_nil job.reload.ad_approved_at
    Portal::WindowChange.open!(job:, actor: hr)
    assert_equal hr.id, job.reload.ad_approved_by_id
    assert job.brief_changes.where(step: "ad").last.changes_made.key?("ad_approved_at"), "the approval is recorded in the brief history"
  end

  test "a draft ad that names a protected attribute is saved only with a written reason" do
    job = briefed_job(ad: false)
    sign_in_as staff_user("hr_pic")
    post staff_job_ad_path(job), params: { ad_text: "Female, max 28 years old." }
    assert_response :unprocessable_content
    assert_nil job.reload.ad_text
    post staff_job_ad_path(job), params: { ad_text: "Female, max 28 years old.", flags_reason: "Test: written reason." }
    assert_equal "Female, max 28 years old.", job.reload.ad_text
    assert_equal "Test: written reason.", job.brief_changes.where(step: "ad").last.changes_made["ad_flags_reason"].last
  end

  test "the knockout questions entered in step 3 are the ones Lamar asks" do
    job = briefed_job
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id)
    open_portal(job)
    get lamar_path(job.public_code)
    assert_response :success
    assert_includes response.body, "Bersedia bekerja shift?"
    assert_includes response.body, "Pengalaman minimal 1 tahun?"
  end

  test "My vacancies offers Add vacancy to editors only and shows the brief state" do
    briefed_job(complete: false)
    sign_in_as staff_user("consultant")
    get staff_jobs_path
    assert_select "a[href=?]", staff_new_job_path, 1
    assert_includes response.body, "Complete the brief"
    assert_select "a[title='View vacancy details'] i.fa-plus"
    sign_out
    sign_in_as staff_user("reviewer")
    get staff_jobs_path
    assert_select "a[href=?]", staff_new_job_path, 0
  end
end
