require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03, through the real routes: who may read and write a brief (D49 (5),
# blueprint §1.2), the ad-approval gate, the house form rules on every brief page (blueprint §5.3:
# no nested form, no disabled submit, the named finish button reaches the controller), no price
# anywhere (D49 (3), E20), the Bahasa wording standard (docs/STANDARD-BAHASA-UI.md, D42-D47) and
# the separately grouped multi-value display (blueprint §3).
class JobFormAccessAndScreensTest < ActionDispatch::IntegrationTest
  include JobFormEngineSupport

  setup { Rails.cache.clear }

  BANNED = /\b(tautan|berkas|unggah\w*|diunggah|mengunggah|terapkan|diterapkan|tatap muka|corong seleksi)\b/i
  PRICE = /\b(harga|biaya|tarif|price|pricing|fee|komisi|invoice|tagihan)\b/i

  def visible_text(html)
    doc = Nokogiri::HTML(html)
    doc.css("script, style").remove
    doc.text.gsub(/\s+/, " ")
  end

  def form_pairs_patch(path, pairs)
    patch path, params: URI.encode_www_form(pairs), headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
  end

  # --- roles ------------------------------------------------------------------------------------
  test "owner, reviewer and admin: every write is refused through the routes, no row or audit changes" do
    job = briefed_job(complete: false)
    %w[owner reviewer admin].each do |role|
      sign_in_as staff_user(role)
      state = [Job.count, JobBriefChange.count, job.reload.attributes.except("updated_at"), job.activities.pluck(:share_percent)]
      post staff_create_job_path, params: { brief: step1_params(title: "Oleh #{role}") }
      assert_redirected_to staff_jobs_path
      (1..4).each do |step|
        get staff_job_brief_step_path(job, step)
        assert_redirected_to staff_jobs_path, "#{role} GET step #{step}"
        patch staff_job_brief_step_path(job, step), params: { brief: { "1" => step1_params(title: "X"), "2" => step2_params(shares: [100, 0, 0, 0, 0]),
                                                                      "3" => step3_params(weights: [100, 0]), "4" => step4_params(package: 5) }[step.to_s] }
        assert_redirected_to staff_jobs_path, "#{role} PATCH step #{step}"
      end
      patch staff_job_brief_step_path(job, 4), params: { brief: step4_params, finish: "1" }
      assert_equal state, [Job.count, JobBriefChange.count, job.reload.attributes.except("updated_at"), job.activities.pluck(:share_percent)], role
      get staff_job_brief_path(job)
      assert_response :success, "#{role} reads the brief"
      sign_out
    end
  end

  test "without a login every brief route is refused and nothing is written" do
    job = briefed_job(complete: false)
    state = [Job.count, JobBriefChange.count, job.reload.title]
    get staff_new_job_path
    assert_redirected_to new_session_path
    post staff_create_job_path, params: { brief: step1_params }
    assert_redirected_to new_session_path
    get staff_job_brief_path(job)
    assert_redirected_to new_session_path
    patch staff_job_brief_step_path(job, 1), params: { brief: step1_params(title: "Tanpa login") }
    assert_redirected_to new_session_path
    patch approve_ad_staff_job_path(job)
    assert_redirected_to new_session_path
    assert_equal state, [Job.count, JobBriefChange.count, job.reload.title]
  end

  test "a step outside 1-4 and an unknown job are not found" do
    job = briefed_job(complete: false)
    sign_in_as staff_user("hr_pic")
    get "/staff/jobs/#{job.id}/brief/5"
    assert_response :not_found
    patch "/staff/jobs/#{job.id}/brief/0", params: { brief: step1_params }
    assert_response :not_found
    get staff_job_brief_path(job_id: Job.maximum(:id) + 1000)
    assert_response :not_found
  end

  # TENANCY=single (ONP-1): a second company cannot exist, so "another company's job" cannot be
  # built. This pins the premise; the unscoped Job.find in JobBriefsController#load_job becomes a
  # cross-tenant hole the day Plan 2 allows a second company (stated, not a finding today).
  test "premise: the database refuses a second client company" do
    company
    refused_by_database do
      ClientCompany.create!(name: "PT Lain", address: "Jl. Lain 2", city: "Bandung", contact_email: "hr@lain.example")
    end
  end

  # --- ad approval ---------------------------------------------------------------------------------
  test "ad approval: refused for a draft brief with the reason on screen; only HR PIC approves a complete one" do
    draft = briefed_job(complete: false)
    sign_in_as staff_user("hr_pic")
    patch approve_ad_staff_job_path(draft)
    assert_redirected_to staff_job_path(draft)
    follow_redirect!
    assert_match(/vacancy brief is incomplete/i, response.body)
    assert_nil draft.reload.ad_approved_at
    sign_out

    done = briefed_job
    %w[consultant owner reviewer admin].each do |role|
      sign_in_as staff_user(role)
      patch approve_ad_staff_job_path(done)
      assert_nil done.reload.ad_approved_at, "#{role} approved the ad"
      sign_out
    end
    sign_in_as staff_user("hr_pic")
    patch approve_ad_staff_job_path(done)
    assert done.reload.ad_approved_at, "control: HR PIC approves a complete brief"
  end

  # --- the wizard forms ------------------------------------------------------------------------------
  test "the named finish button reaches the controller; Save alone keeps the draft" do
    job = briefed_job(package: 2, complete: false) # no technical test: step 4 is the last step
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    _, received = press("Save", {}, button_name: "commit")
    assert_nil received["finish"], "Save sent finish"
    refute job.reload.brief_complete?
    get staff_job_brief_step_path(job, 4)
    status, received = press("1", {}, button_name: "finish")
    assert_equal "1", received["finish"]
    assert_equal 302, status
    assert job.reload.brief_complete?, "the finish button did not complete a valid brief"
  end

  test "every brief page, in every state, keeps the house form rules and the wording standard" do
    draft = briefed_job(complete: false)
    done = briefed_job(golongan: 4, package: 4)
    locked = briefed_job(golongan: 6, package: 4)
    open_stage!(locked, "S1")
    applied = briefed_job
    application_on!(applied)
    pages = { "new" => staff_new_job_path }
    { "draft" => draft, "complete" => done, "locked" => locked, "applied" => applied }.each do |label, job|
      pages["#{label} brief"] = staff_job_brief_path(job)
      pages["#{label} job"] = staff_job_path(job)
      (1..4).each { |s| pages["#{label} step #{s}"] = staff_job_brief_step_path(job, s) }
    end
    pages["jobs"] = staff_jobs_path
    %w[hr_pic consultant owner].each do |role|
      sign_in_as staff_user(role)
      pages.each do |label, path|
        get path
        next if response.redirect? && role == "owner"

        assert_response :success, "#{role} #{label}"
        assert_engine_house_rules(response.body, "#{role} #{label}")
        text = visible_text(response.body)
        assert_match(/[Vv]acanc/, text, "#{role} #{label}: control, the page text was read")
        refute_match BANNED, text, "#{role} #{label}: banned word"
        refute_match PRICE, text, "#{role} #{label}: a price word"
        Nokogiri::HTML(response.body).css("button, input[type=submit]").each do |b|
          refute_match(/\b(kirim|send)\b/i, b.text + b["value"].to_s, "#{role} #{label}: a brief save is Save, not Send")
        end
      end
      sign_out
    end
  end

  test "a refused save re-renders with the house errors, the house rules, and the typed values kept" do
    job = briefed_job(complete: false)
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 2)
    name = Nokogiri::HTML(response.body).css("input[name$='[share_percent]']").first["name"]
    status, = press("Save & next", { name => "lima" }, button_name: "commit")
    assert_equal 422, status
    assert_engine_house_rules(response.body, "step 2 refused")
    assert_select "input[name=?][value=?]", name, "lima"
    refute_match BANNED, visible_text(response.body)
    assert_match(/whole number/, response.body)
  end

  test "every Rp amount on the brief and job pages is the job's own salary band" do
    job = briefed_job
    sign_in_as staff_user("hr_pic")
    allowed = [job.salary_min, job.salary_max].map { |v| v.to_s.reverse.scan(/\d{1,3}/).join(".").reverse }
    [staff_job_brief_path(job), staff_job_path(job), staff_job_brief_step_path(job, 3)].each do |path|
      get path
      amounts = visible_text(response.body).scan(/Rp\s?([\d.]+)/).flatten.uniq
      assert_includes amounts, allowed.first, "#{path}: control, the salary itself was found" if path == staff_job_brief_path(job)
      assert_empty amounts - allowed, "#{path}: an Rp amount that is not the salary band: #{(amounts - allowed).inspect}"
    end
  end

  test "placements render as one list item per city with a count, never comma-joined; empty state when none" do
    job = briefed_job
    save_step!(job, "3", with_requirement_ids(job, step3_params.merge(placements: %w[Bekasi Karawang Cikarang])))
    sign_in_as staff_user("reviewer")
    get staff_job_brief_path(job)
    assert_select "ul.job-brief-chips li", text: /Bekasi/, count: 1
    assert_select "ul.job-brief-chips li", 3
    refute_match(/Bekasi, Karawang/, visible_text(response.body), "placements comma-joined on the brief page")
    draft = briefed_job(complete: false)
    draft.update_columns(placements: [])
    get staff_job_brief_path(draft)
    assert_match(/No placement yet/, response.body)
  end
  test "a row id from another job is refused, through the route and the service; the other job is untouched" do
    mine = briefed_job(complete: false)
    other = briefed_job(complete: false)
    foreign = other.activities.first
    before = foreign.slice(:description, :share_percent, :job_id)
    params = step2_params
    params[:activities]["0"][:id] = foreign.id.to_s
    params[:activities]["0"][:description] = "Dibajak"
    sign_in_as staff_user("hr_pic")
    patch staff_job_brief_step_path(mine, 2), params: { brief: params }
    assert_response :not_found
    assert_raises(ActiveRecord::RecordNotFound) { Briefs::SaveStep.call(job: mine.reload, step: "2", params:, actor: staff_user("hr_pic")) }
    assert_equal before, foreign.reload.slice(:description, :share_percent, :job_id)
    req = other.requirements.first
    p3 = with_requirement_ids(mine, step3_params)
    p3[:requirements]["0"][:id] = req.id.to_s
    patch staff_job_brief_step_path(mine, 3), params: { brief: p3 }
    assert_response :not_found
    assert_equal other.id, req.reload.job_id
  end
end
