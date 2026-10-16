require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03, confirming run 2 (2026-10-10): attacks on the builder's fixes for
# F-01..F-05 themselves. The run-1 files are not edited (hashes-03.txt).
#   F-03/F-04: Requirement has_one :knockout_question, dependent: :nullify; SaveStep#sync_knockouts
#              re-links by text, then by previous requirement, parking at position = -id first.
#   F-01:      Params#bounded caps integers at INT_MAX and salary at BIGINT_MAX.
#   F-05:      Bahasa checks for headcount 0, salary 0, Golongan outside 1-8.
#   F-02:      BriefCheck#one_stage_problems compares names trimmed and case-insensitive.
class JobFormRun2FixesServiceTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  INT_MAX = 2_147_483_647
  BIGINT_MAX = 9_223_372_036_854_775_807

  # Wajib rows with the given knockouts (nil = no question) and one sebaiknya line at 100.
  def wajib_rows(knockouts)
    rows = knockouts.each_with_index.to_h do |ko, i|
      [i.to_s, { tier: "wajib", text: "Syarat #{i + 1}", cv_evidence: "CV", knockout: ko }]
    end
    rows["6"] = { tier: "sebaiknya", text: "Sebaiknya", cv_evidence: "CV", weight: "100" }
    step3_params.merge(requirements: rows)
  end

  def questions(job) = job.reload.knockout_questions.order(:position).map { |q| [q.id, q.text, q.requirement&.text] }

  def assert_no_orphans(job, label)
    orphans = job.reload.knockout_questions.where(requirement_id: nil)
    assert_empty orphans.pluck(:id, :text), "#{label}: a question left with no requirement (it is still asked on Lamar)"
    assert(job.knockout_questions.all? { |q| q.position.positive? }, "#{label}: a question left parked on a negative position")
    assert_equal job.knockout_questions.count, job.knockout_questions.distinct.count(:position)
  end

  # --- F-03 / F-04: re-linking -----------------------------------------------------------------
  test "after an application, swapping two questions between wajib lines keeps every id with its own text" do
    job = briefed_job(complete: false)
    save_step!(job, "3", wajib_rows(["A?", "B?", nil]))
    application_on!(job)
    before = job.knockout_questions.to_h { |q| [q.text, q.id] }
    params = with_requirement_ids(job, wajib_rows(["B?", "A?", nil]))
    assert run_step(job.reload, "3", params).ok?
    after = job.reload.knockout_questions.to_h { |q| [q.text, q.id] }
    assert_equal before, after, "a question id changed or swapped its text after an application"
    assert_equal({ "B?" => "Syarat 1", "A?" => "Syarat 2" }, job.knockout_questions.to_h { |q| [q.text, q.requirement.text] })
    assert_no_orphans(job, "swap")
  end

  test "after an application, a question moved to a NEW wajib line (old line deleted) keeps its id" do
    job = briefed_job(complete: false)
    save_step!(job, "3", wajib_rows(["A?", "B?", nil]))
    application_on!(job)
    ids = job.knockout_questions.to_h { |q| [q.text, q.id] }
    params = with_requirement_ids(job, wajib_rows([nil, "B?", nil]))
    params[:requirements]["0"] = { tier: "wajib", text: "Syarat 1", cv_evidence: "CV" }
    params[:requirements]["0"].delete(:id)
    params[:requirements]["3"] = { tier: "wajib", text: "Syarat baru", cv_evidence: "CV", knockout: "A?" }
    # Line 1 (old owner of A?) is removed by blanking it.
    params[:requirements]["0"] = { tier: "wajib", text: "", cv_evidence: "", knockout: "", id: job.requirements.find_by(text: "Syarat 1").id.to_s }
    assert run_step(job.reload, "3", params).ok?
    assert_equal ids, job.reload.knockout_questions.to_h { |q| [q.text, q.id] }
    assert_equal "Syarat baru", job.knockout_questions.find_by(text: "A?").requirement.text
    assert_no_orphans(job, "move to new line")
  end

  test "duplicate question texts on two wajib lines: ids survive a resave and a swap, nothing orphaned" do
    job = briefed_job(complete: false)
    save_step!(job, "3", wajib_rows(["Sama?", "Sama?", "Lain?"]))
    ids = job.knockout_questions.pluck(:id).sort
    assert_equal 3, ids.size
    application_on!(job)
    assert run_step(job.reload, "3", with_requirement_ids(job, wajib_rows(["Sama?", "Lain?", "Sama?"]))).ok?
    assert_equal ids, job.reload.knockout_questions.pluck(:id).sort
    refute run_step(job.reload, "3", with_requirement_ids(job, wajib_rows(["Sama?", "Sama?", "Sama?"]))).ok?,
           "changing the multiset of texts after an application must be refused"
    refute run_step(job.reload, "3", with_requirement_ids(job, wajib_rows(["Sama?", "Lain?", nil]))).ok?,
           "dropping one of two duplicates after an application must be refused"
    assert_equal ids, job.reload.knockout_questions.pluck(:id).sort
    assert_no_orphans(job, "duplicates")
  end

  test "after an application, the texts saved without row ids keep every id (the F-03 path, three lines)" do
    job = briefed_job(complete: false)
    save_step!(job, "3", wajib_rows(["A?", "B?", "C?"]))
    application = application_on!(job)
    ids = job.knockout_questions.order(:position).pluck(:id)
    assert run_step(job.reload, "3", wajib_rows(["A?", "B?", "C?"])).ok?
    assert_equal ids, job.reload.knockout_questions.order(:position).pluck(:id)
    assert_equal application.knockout_answers.keys.sort, job.knockout_questions.pluck(:id).map(&:to_s).sort
    assert_no_orphans(job, "no ids")
  end

  test "before applications: deleting the line that owns a question removes the question; no orphan is left or asked" do
    job = briefed_job(complete: false)
    save_step!(job, "3", wajib_rows(["A?", "B?", "C?"]))
    params = with_requirement_ids(job, wajib_rows(["A?", "B?", "C?"]))
    params[:requirements]["1"] = { id: params[:requirements]["1"][:id], tier: "wajib", text: "", cv_evidence: "", knockout: "" }
    assert run_step(job.reload, "3", params).ok?
    assert_equal %w[A? C?], job.reload.knockout_questions.order(:position).pluck(:text)
    assert_no_orphans(job, "line deleted")
    assert_empty Briefs::BriefCheck.new(job).problems.select { |p| p.message.include?("knockout") }, "2 questions remain, inside 2-3"
  end

  test "a long sequence of edits before applications never leaves an orphan, a parked position or a duplicate position" do
    job = briefed_job(complete: false)
    [["A?", nil, "B?"], [nil, "C?", "B?"], ["B?", "C?", nil], ["C?", "B?", "A?"], ["A?", nil, nil], [nil, nil, "Z?"], ["Z?", "Y?", "X?"]].each_with_index do |kos, i|
      result = run_step(job.reload, "3", with_requirement_ids(job, wajib_rows(kos)))
      assert result.ok?, "edit #{i}: #{result.errors.inspect}"
      assert_equal kos.compact, job.reload.knockout_questions.order(:position).map(&:text), "edit #{i}"
      assert_no_orphans(job, "edit #{i}")
    end
  end

  test "legacy questions (no requirement) keep their positions first; new ones follow without collision" do
    job = briefed_job(complete: false)
    job.knockout_questions.destroy_all
    legacy = job.knockout_questions.create!(position: 1, text: "Pertanyaan lama?")
    save_step!(job, "3", with_requirement_ids(job, wajib_rows(["A?", "B?", nil])))
    save_step!(job, "3", with_requirement_ids(job, wajib_rows([nil, "A?", "B?"])))
    assert_equal [[legacy.id, 1]], job.reload.knockout_questions.where(requirement_id: nil).pluck(:id, :position)
    assert_equal ["Pertanyaan lama?", "A?", "B?"], job.knockout_questions.order(:position).pluck(:text)
  end

  # --- F-01: bounded --------------------------------------------------------------------------
  test "bounded: exactly INT_MAX / BIGINT_MAX are stored, one more is refused with the house sentence, never an exception" do
    job = briefed_job(complete: false)
    defects = []
    check = lambda do |label, step, params, ok, &verify|
      result = run_step(job.reload, step, params)
      if ok && !result.ok? then defects << "#{label}: refused #{result.errors.inspect}"
      elsif !ok && result.ok? then defects << "#{label}: accepted"
      elsif !ok && result.errors.none? { |e| e.include?("too large") } then defects << "#{label}: no size message #{result.errors.inspect}"
      elsif ok && verify && !verify.call(job.reload) then defects << "#{label}: stored value wrong"
      end
    rescue StandardError => e
      defects << "#{label}: #{e.class}: #{e.message[0, 140]}"
    end
    check.call("headcount INT_MAX", "1", step1_params.merge(headcount: INT_MAX.to_s), true) { |j| j.headcount == INT_MAX }
    check.call("headcount INT_MAX+1", "1", step1_params.merge(headcount: (INT_MAX + 1).to_s), false)
    check.call("headcount leading zeros", "1", step1_params.merge(headcount: "0000000000000000000002"), true) { |j| j.headcount == 2 }
    check.call("salary BIGINT_MAX", "3", step3_params.merge(salary_min: "1", salary_max: BIGINT_MAX.to_s), true) { |j| j.salary_max == BIGINT_MAX }
    check.call("salary BIGINT_MAX dotted", "3", step3_params.merge(salary_min: "1", salary_max: "9.223.372.036.854.775.807"), true) { |j| j.salary_max == BIGINT_MAX }
    check.call("salary BIGINT_MAX+1", "3", step3_params.merge(salary_max: (BIGINT_MAX + 1).to_s), false)
    check.call("salary BIGINT_MAX+1 dotted", "3", step3_params.merge(salary_max: "9.223.372.036.854.775.808"), false)
    check.call("golongan INT_MAX+1", "1", step1_params.merge(golongan: (INT_MAX + 1).to_s), false)
    check.call("package INT_MAX+1", "4", step4_params.merge(package: (INT_MAX + 1).to_s), false)
    assert_empty defects, defects.join("\n")
    # Non-size values at INT_MAX are refused by their own rule, not stored.
    refute run_step(job.reload, "1", step1_params.merge(golongan: INT_MAX.to_s)).ok?
    refute run_step(job.reload, "4", step4_params.merge(package: INT_MAX.to_s)).ok?
    refute run_step(job.reload, "2", step2_params(shares: [INT_MAX, 20, 20, 15, 15])).ok?
  end

  # --- F-05 ------------------------------------------------------------------------------------
  test "zero and out-of-range values are refused with the house sentence, on new and saved jobs" do
    { "headcount 0" => ["1", step1_params.merge(headcount: "0"), /at least 1 person/],
      "headcount 00" => ["1", step1_params.merge(headcount: "00"), /at least 1 person/],
      "salary min 0" => ["3", step3_params.merge(salary_min: "0"), /more than Rp0/],
      "salary max Rp 0" => ["3", step3_params.merge(salary_max: "Rp 0"), /more than Rp0/],
      "golongan 9" => ["1", step1_params.merge(golongan: "9"), /G1 to G8/] }.each do |label, (step, params, sentence)|
      job = briefed_job(complete: false)
      result = run_step(job, step, params)
      refute result.ok?, label
      assert(result.errors.any? { |e| e.match?(sentence) }, "#{label}: #{result.errors.inspect}")
      # A Rails default validation message (attribute name + generic phrase) must never reach the user.
      assert(result.errors.none? { |e| e.match?(/\b(is not included in the list|is not a number|can't be blank|must be greater than|must be less than|Salary min|Salary max)\b/) }, "#{label}: #{result.errors.inspect}")
    end
    fresh = run_step(Job.new(client_company: company), "1", step1_params.merge(golongan: "0"))
    refute fresh.ok?
    assert(fresh.errors.any? { |e| e.include?("G1 to G8") }, fresh.errors.inspect)
  end

  # --- F-02 ------------------------------------------------------------------------------------
  # The same competency typed twice with a variation a person does not see, or does not mean.
  test "one competency, one stage: names that differ only in invisible or spacing ways are the same competency" do
    variants = {
      "double inner space" => ["Kerja tim", "Kerja  tim"],
      "non-breaking space inside" => ["Kerja tim", "Kerja tim"],
      "trailing non-breaking space" => ["Kerja tim", "Kerja tim "],
      "tab inside" => ["Kerja tim", "Kerja\ttim"],
      "decomposed accent (NFD vs NFC)" => ["Etika kerja ré", "Etika kerja ré"],
      "upper case" => ["Kerja tim", "KERJA TIM"]
    }
    missed = variants.filter_map do |label, (a, b)|
      job = briefed_job(golongan: 2, package: 3, complete: false)
      comps = competencies_for(%w[L1 L2 L3 L4 L5 I], 3)
      comps["6"] = comps["0"].merge(name: a, stage_code: "S3")
      comps["7"] = comps["0"].merge(name: b, stage_code: "S5")
      result = run_step(job, "4", step4_params.merge(competencies: comps))
      next "#{label}: refused at save #{result.errors.inspect}" unless result.ok?

      label if Briefs::BriefCheck.new(job.reload).problems.none? { |p| p.message.include?("is assessed in 2 stages") }
    end
    assert_empty missed, "the same competency in two stages was not caught for: #{missed.join(', ')}"
  end

  # Kept apart from the variants test above, which is red while F-06 is open and so cannot show
  # a regression of what the fix already covers (case and outer spaces).
  test "one competency, one stage: upper case and outer spaces are the same competency (the F-02 fix)" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    comps = competencies_for(%w[L1 L2 L3 L4 L5 I], 3)
    comps["6"] = comps["0"].merge(name: "Kerja tim", stage_code: "S3")
    comps["7"] = comps["0"].merge(name: "  KERJA TIM ", stage_code: "S5")
    save_step!(job, "4", step4_params.merge(competencies: comps))
    assert(Briefs::BriefCheck.new(job.reload).problems.any? { |p| p.message.include?("is assessed in 2 stages") })
    refute Briefs::Complete.call(job:, actor: staff_user("hr_pic")).ok?
  end

  test "one competency, one stage control: the same name twice in the SAME stage, and two different names, pass the rule" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    comps = competencies_for(%w[L1 L2 L3 L4 L5 I], 3)
    comps["6"] = comps["0"].merge(name: "Kerja tim", stage_code: "S3")
    comps["7"] = comps["0"].merge(name: "Kerja tim", stage_code: "S3")
    comps["8"] = comps["0"].merge(name: "Kerja mandiri", stage_code: "S5")
    save_step!(job, "4", step4_params.merge(competencies: comps))
    assert_empty Briefs::BriefCheck.new(job.reload).problems.select { |p| p.message.include?("stages (") }
  end
end

class JobFormRun2FixesScreenTest < ActionDispatch::IntegrationTest
  include JobFormEngineSupport

  setup { Rails.cache.clear }

  test "Lamar asks exactly the brief's questions after re-links: no orphan, no duplicate, in position order" do
    job = briefed_job(complete: false)
    save_step!(job, "3", with_requirement_ids(job, step3_params.merge(requirements: {
      "0" => { tier: "wajib", text: "S1", cv_evidence: "CV", knockout: "A?" },
      "1" => { tier: "wajib", text: "S2", cv_evidence: "CV" },
      "2" => { tier: "wajib", text: "S3", cv_evidence: "CV", knockout: "B?" },
      "6" => { tier: "sebaiknya", text: "S4", cv_evidence: "CV", weight: "100" } })))
    params = with_requirement_ids(job, step3_params.merge(requirements: {
      "0" => { tier: "wajib", text: "S1", cv_evidence: "CV" },
      "1" => { tier: "wajib", text: "S2", cv_evidence: "CV", knockout: "C?" },
      "2" => { tier: "wajib", text: "S3", cv_evidence: "CV", knockout: "A?" },
      "6" => { tier: "sebaiknya", text: "S4", cv_evidence: "CV", weight: "100" } }))
    save_step!(job, "3", params)
    assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id)
    open_portal(job)
    get lamar_path(job.public_code)
    assert_response :success
    asked = Nokogiri::HTML(response.body).css("input[type=radio][name^='knockout[']").map { |i| i["name"][/\d+/].to_i }.uniq
    assert_equal job.knockout_questions.order(:position).pluck(:id), asked
    assert_equal %w[C? A?], job.knockout_questions.order(:position).pluck(:text)
    assert_match "C?", response.body
    refute_match "B?", response.body, "a removed question is still asked"
  end

  test "F-01 / F-04 through the screen: 422 with the house message, never an error page" do
    job = briefed_job(complete: false)
    sign_in_as staff_user("consultant")
    get staff_job_brief_step_path(job, 1)
    status, = press("Save & next", { "brief[headcount]" => "99999999999" }, button_name: "commit")
    assert_equal 422, status
    assert_match(/too large/, response.body)
    get staff_job_brief_step_path(job, 3)
    status, = press("Save & next", { "brief[salary_max]" => "99999999999999999999" }, button_name: "commit")
    assert_equal 422, status
    assert_match(/too large/, response.body)
  end
end
