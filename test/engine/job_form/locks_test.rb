require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03: blueprint §2.2 rule 3 (once a stage opens, the scoring parts of the brief
# are frozen), the knockout freeze once an application exists (open item O-3, answers keyed by
# question id), and "a complete brief stays complete". Attacked through the service with raw
# params, and through the controller with a form rendered BEFORE the stage opened (stale form).
class JobFormLocksServiceTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  def stage_state(job) = job.stages.order(:code).pluck(:code, :weight, :threshold, :status)

  def brief_state(job)
    job.reload
    [job.golongan, job.package, job.package_override_reason, job.stage_plan,
     job.requirements.map { |r| r.slice(:tier, :text, :cv_evidence, :weight) },
     job.knockout_questions.order(:position).pluck(:id, :text),
     job.competencies.map { |c| c.slice(:name, :layer, :stage_code) }]
  end

  test "rule 3: after a stage opens, every scoring field is refused through the service" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S1")
    before_brief = brief_state(job)
    before_stages = stage_state(job)
    audit = job.brief_changes.count
    w = Briefs::StagePlan.default_weights(4)
    attempts = {
      "golongan" => ["1", step1_params(golongan: 5)],
      "requirement weight" => ["3", with_requirement_ids(job, step3_params(weights: [50, 50]))],
      "requirement text" => ["3", with_requirement_ids(job, step3_params).tap { |p| p[:requirements]["2"][:text] = "Diubah" }],
      "knockout text" => ["3", with_requirement_ids(job, step3_params(knockouts: ["Diubah?", "Pengalaman minimal 1 tahun?"]))],
      "package" => ["4", step4_params(package: 5)],
      "stage weight" => ["4", step4_params(package: 4, weights: w.merge("S1" => w["S1"] + 5, "S5" => w["S5"] - 5))],
      "threshold" => ["4", step4_params(package: 4, threshold: "10")],
      "competencies" => ["4", step4_params(package: 4, layers: %w[L1 L2 L3 L4 L5 I I])]
    }
    accepted = attempts.filter_map { |label, (step, params)| label if run_step(job.reload, step, params).ok? }
    assert_empty accepted, "rule 3 let these through after S1 opened: #{accepted.inspect}"
    assert_equal before_brief, brief_state(job)
    assert_equal before_stages, stage_state(job), "an opened (or any) stage row changed"
    assert_equal audit, job.brief_changes.count, "a refused save wrote an audit row"
  end

  test "rule 3 control: non-scoring fields stay editable after a stage opens" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S1")
    assert run_step(job, "1", step1_params(golongan: 4, title: "Judul baru")).ok?
    assert_equal "Judul baru", job.reload.title
    assert run_step(job, "3", step3_params.except(:requirements).merge(salary_max: "7.000.000")).ok?
    assert_equal 7_000_000, job.reload.salary_max
    assert job.brief_complete?
  end

  test "rule 3: a locked brief never re-syncs its stages, and SyncStages refuses a locked job" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S1")
    assert_raises(Briefs::SyncStages::Refused) { Briefs::SyncStages.call(job.reload) }
  end

  test "a locked draft brief cannot be completed" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    Briefs::SyncStages.call(job.tap { |j| j.update_columns(brief_status: "draft") })
    open_stage!(job, "S1")
    result = Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic"))
    refute result.ok?
    refute job.reload.brief_complete?
  end

  # --- knockout freeze (O-3) ----------------------------------------------------------------------
  test "knockout freeze: once an application exists, text, removal and addition are refused" do
    job = briefed_job
    application_on!(job)
    ids = job.knockout_questions.order(:position).pluck(:id, :text)
    {
      "edit" => step3_params(knockouts: ["Bersedia bekerja shift malam?", "Pengalaman minimal 1 tahun?"]),
      "remove" => step3_params(knockouts: ["Bersedia bekerja shift?"]),
      "add" => step3_params(knockouts: ["Bersedia bekerja shift?", "Pengalaman minimal 1 tahun?", "Punya SIM?"])
    }.each do |label, params|
      refute run_step(job.reload, "3", with_requirement_ids(job, params)).ok?, "#{label} accepted after an application"
      assert_equal ids, job.reload.knockout_questions.order(:position).pluck(:id, :text), label
    end
    params = with_requirement_ids(job, step3_params)
    params[:requirements]["2"][:text] = "Syarat wajib tanpa knockout, diperjelas"
    assert run_step(job, "3", params).ok?, "control: a requirement without a question stays editable"
  end

  test "before any application, editing a question's wording keeps its id (answers are keyed by id)" do
    job = briefed_job
    ids = job.knockout_questions.order(:position).pluck(:id)
    save_step!(job, "3", with_requirement_ids(job, step3_params(knockouts: ["Bersedia bekerja shift malam?", "Pengalaman minimal 1 tahun?"])))
    assert_equal ids, job.reload.knockout_questions.order(:position).pluck(:id)
  end

  # The freeze compares question TEXTS only. A save whose rows carry no ids (a form re-built, a
  # second tab opened before the first save, a raw POST) deletes every requirement and builds new
  # ones; dependent: :destroy deletes the questions and new ones are created with new ids.
  test "knockout freeze: the same texts saved without row ids must keep the question ids" do
    job = briefed_job
    application = application_on!(job)
    ids = job.knockout_questions.order(:position).pluck(:id)
    run_step(job.reload, "3", step3_params)
    after = job.reload.knockout_questions.order(:position).pluck(:id)
    assert_equal ids, after,
                 "question ids changed after an application exists; its answers #{application.reload.knockout_answers.keys.inspect} now point at nothing (#{after.inspect})"
  end

  test "knockout freeze: moving a question to another wajib line must keep its id" do
    job = briefed_job
    application_on!(job)
    ids = job.knockout_questions.order(:position).pluck(:id)
    params = with_requirement_ids(job, step3_params)
    rows = params[:requirements]
    # wajib 1 and 3 swap their question: wajib 1 loses "Bersedia bekerja shift?", wajib 3 gains it.
    rows["2"][:knockout] = rows["0"][:knockout]
    rows["0"][:knockout] = rows["1"][:knockout]
    rows["1"][:knockout] = nil
    rows["2"], rows["0"] = rows["0"], rows["2"]
    begin
      run_step(job.reload, "3", params)
    rescue StandardError => e
      flunk "the save raised instead of being refused or kept: #{e.class}: #{e.message.lines.first.strip}"
    end
    assert_equal ids.sort, job.reload.knockout_questions.pluck(:id).sort, "a question was deleted and re-created after an application"
  end

  # Unique index (job_id, position) + in-place renumbering in sync_knockouts.
  test "adding a question to a wajib line between two lines that have one is saved or refused, never an exception" do
    job = briefed_job(complete: false)
    rows = { "0" => { tier: "wajib", text: "Syarat 1", cv_evidence: "CV", knockout: "A?" },
             "1" => { tier: "wajib", text: "Syarat 2", cv_evidence: "CV" },
             "2" => { tier: "wajib", text: "Syarat 3", cv_evidence: "CV", knockout: "B?" },
             "3" => { tier: "sebaiknya", text: "Syarat 4", cv_evidence: "CV", weight: "100" } }
    save_step!(job, "3", step3_params.merge(requirements: rows))
    params = with_requirement_ids(job, step3_params.merge(requirements: rows.deep_dup))
    params[:requirements]["1"][:knockout] = "C?"
    result = begin
      run_step(job.reload, "3", params)
    rescue StandardError => e
      flunk "#{e.class}: #{e.message[0, 200]}"
    end
    if result.ok?
      assert_equal %w[A? C? B?].sort, job.reload.knockout_questions.pluck(:text).sort
    else
      # Never a Rails default validation message (attribute name + generic phrase).
      assert(result.errors.none? { |m| m.match?(/\b(is not included in the list|is not a number|can't be blank|must be greater than|must be less than)\b/) }, result.errors.inspect)
    end
  end

  # --- complete stays complete ----------------------------------------------------------------
  test "a complete brief cannot be saved back into an incomplete state, and nothing is half-saved" do
    job = briefed_job
    snapshot = [job.activities.pluck(:share_percent), job.requirements.pluck(:weight), job.stage_plan, job.competencies.pluck(:layer)]
    w = Briefs::StagePlan.default_weights(3)
    {
      "2" => step2_params(shares: [30, 20, 20, 15, 14]),
      "3" => with_requirement_ids(job, step3_params(weights: [60, 39])),
      "4" => step4_params(weights: w.merge("S5" => w["S5"] - 1))
    }.each do |step, params|
      result = run_step(job.reload, step, params)
      refute result.ok?, "step #{step} broke a complete brief"
      assert_includes result.errors.first, "is complete"
    end
    refute run_step(job.reload, "4", step4_params(layers: %w[L2 L3 L5])).ok?, "coverage broken on a complete brief"
    refute run_step(job.reload, "1", step1_params.merge(title: "")).ok?
    assert job.reload.brief_complete?
    assert_equal snapshot, [job.activities.pluck(:share_percent), job.requirements.pluck(:weight), job.stage_plan, job.competencies.pluck(:layer)]
  end

  test "brief_status cannot be set through params on any step" do
    draft = briefed_job(complete: false)
    params = { "1" => step1_params, "2" => step2_params, "3" => step3_params, "4" => step4_params }
    params.each do |step, p|
      run_step(draft.reload, step, p.merge(brief_status: "complete", brief_completed_at: Time.current.iso8601))
      assert_equal "draft", draft.reload.brief_status, "step #{step}"
    end
    done = briefed_job
    params.each do |step, p|
      run_step(done.reload, step, (step == "3" ? with_requirement_ids(done, p) : p).merge(brief_status: "draft"))
      assert_equal "complete", done.reload.brief_status, "step #{step}"
    end
  end

  test "completing twice records one completion" do
    job = briefed_job
    rows = job.brief_changes.where(step: "complete").count
    assert Briefs::Complete.call(job:, actor: staff_user("consultant")).ok?
    assert_equal rows, job.brief_changes.where(step: "complete").count
  end
end

class JobFormLocksControllerTest < ActionDispatch::IntegrationTest
  include JobFormEngineSupport

  setup { Rails.cache.clear }

  test "a step-4 form rendered before the stage opened is refused when posted after (stale form)" do
    job = briefed_job(golongan: 4, package: 4)
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    assert_response :success
    stale = response.body
    before = [job.reload.stage_plan, job.stages.order(:code).pluck(:code, :weight, :threshold)]
    open_stage!(job, "S1")
    # The operator's browser still shows the old form; they lower S1's threshold and press Save.
    doc = Nokogiri::HTML(stale)
    button = doc.css("form button[value='Save']").first
    pairs = browser_pairs(button.ancestors("form").first, button, "brief[stage_plan][S1][threshold]" => "5")
    patch staff_job_brief_step_path(job, 4), params: URI.encode_www_form(pairs.reject { |n, _| n == "_method" }),
                                             headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_response :unprocessable_content
    assert_equal before, [job.reload.stage_plan, job.stages.order(:code).pluck(:code, :weight, :threshold)]
  end

  test "a step-3 and a step-1 form rendered before the stage opened are refused for their scoring parts" do
    job = briefed_job(golongan: 4, package: 4)
    sign_in_as staff_user("consultant")
    get staff_job_brief_step_path(job, 3)
    stale3 = Nokogiri::HTML(response.body)
    get staff_job_brief_step_path(job, 1)
    stale1 = Nokogiri::HTML(response.body)
    knockouts = job.knockout_questions.order(:position).pluck(:id, :text)
    open_stage!(job, "S1")

    b3 = stale3.css("form button[value='Save & next']").first
    kname = stale3.css("input[name$='[knockout]']").first["name"]
    patch staff_job_brief_step_path(job, 3), params: URI.encode_www_form(browser_pairs(b3.ancestors("form").first, b3, kname => "Diubah?").reject { |n, _| n == "_method" }),
                                             headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_response :unprocessable_content
    assert_equal knockouts, job.reload.knockout_questions.order(:position).pluck(:id, :text)

    b1 = stale1.css("form button[value='Save & next']").first
    patch staff_job_brief_step_path(job, 1), params: URI.encode_www_form(browser_pairs(b1.ancestors("form").first, b1, "brief[golongan]" => "6").reject { |n, _| n == "_method" }),
                                             headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_response :unprocessable_content
    assert_equal 4, job.reload.golongan
  end

  test "locked screens: step 4 shows no form, step 3 shows no requirement fields, a raw PATCH is refused" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S1")
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 4)
    assert_response :success
    assert_select "form.job-brief-form", 0
    assert_match(/locked/i, response.body)
    get staff_job_brief_step_path(job, 3)
    assert_select "input[name*='[requirements]']", 0
    patch staff_job_brief_step_path(job, 4), params: { brief: step4_params(package: 5) }
    assert_response :unprocessable_content
    assert_equal 4, job.reload.package
  end

  test "knockout fields are readonly (not disabled) once an application exists, and their values still post" do
    job = briefed_job
    application_on!(job)
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 3)
    doc = Nokogiri::HTML(response.body)
    fields = doc.css("input[name$='[knockout]']")
    assert fields.any?
    assert(fields.all? { |f| f.key?("readonly") && !f.key?("disabled") })
    status, received = press("Save & next")
    assert_includes [200, 302, 303], status
    posted = received["brief"]["requirements"].values.filter_map { |r| r["knockout"].presence }
    assert_equal job.knockout_questions.order(:position).pluck(:text), posted
  end
  test "locked screens control: the operator can still save the non-scoring parts of steps 1, 2 and 3" do
    job = briefed_job(golongan: 4, package: 4)
    open_stage!(job, "S1")
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 1)
    status, = press("Save & next", { "brief[title]" => "Supervisor Lini 2" }, button_name: "commit")
    assert_equal 302, status, "locked step 1 could not be saved"
    get staff_job_brief_step_path(job, 3)
    status, = press("Save & next", { "brief[salary_max]" => "6.500.000" }, button_name: "commit")
    assert_equal 302, status, "locked step 3 could not be saved"
    get staff_job_brief_step_path(job, 2)
    status, = press("Save & next", {}, button_name: "commit")
    assert_equal 302, status, "locked step 2 could not be saved"
    assert_equal ["Supervisor Lini 2", 6_500_000, 4], [job.reload.title, job.salary_max, job.golongan]
  end
  test "through the screen: typing a question into the middle wajib line is saved or refused, never an error page" do
    job = briefed_job(complete: false)
    rows = { "0" => { tier: "wajib", text: "Syarat 1", cv_evidence: "CV", knockout: "A?" },
             "1" => { tier: "wajib", text: "Syarat 2", cv_evidence: "CV" },
             "2" => { tier: "wajib", text: "Syarat 3", cv_evidence: "CV", knockout: "B?" },
             "6" => { tier: "sebaiknya", text: "Syarat 4", cv_evidence: "CV", weight: "100" } }
    save_step!(job, "3", step3_params.merge(requirements: rows))
    sign_in_as staff_user("hr_pic")
    get staff_job_brief_step_path(job, 3)
    assert_equal "", Nokogiri::HTML(response.body).at_css("input[name='brief[requirements][1][knockout]']")["value"].to_s
    status = begin
      press("Save & next", { "brief[requirements][1][knockout]" => "C?" }, button_name: "commit").first
    rescue StandardError => e
      flunk "the operator gets an error page: #{e.class}: #{e.message.lines.first.strip}"
    end
    assert_includes [302, 422], status
  end
end
