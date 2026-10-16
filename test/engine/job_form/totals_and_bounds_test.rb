require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03: "sums to exactly 100", the 5-8 activity and 2-3 knockout bounds, the
# knockout-only-on-wajib rule, integer rupiah and every malformed number, through Briefs::Totals,
# Briefs::SaveStep and Briefs::BriefCheck. Each positive assertion sits beside its control.
class JobFormTotalsAndBoundsTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  # A Rails default validation message, as opposed to the house sentence (which is also English since A3).
  ENGLISH = /is not included in the list|is not a number|can't be blank|must be greater than|must be less than|is invalid|out of range/i
  # Model attribute names as Rails humanizes them when id.yml has no attribute translation; they
  # reach the screen through SaveStep's RecordInvalid rescue (full_messages).
  ENGLISH_ATTRIBUTE = /\b(Salary min|Salary max|Share percent|Employment type|Golongan)\b/

  def problems(job, step = nil)
    list = Briefs::BriefCheck.new(job.reload).problems
    (step ? list.select { |p| p.step == step } : list).map(&:message)
  end

  def activities(shares) = step2_params(shares:)

  # --- Totals ----------------------------------------------------------------------------------
  test "Totals.hundred? is exactly 100, whole non-negative integers only" do
    assert Briefs::Totals.hundred?([100])
    assert Briefs::Totals.hundred?([0, 100]), "a zero share is a whole number"
    assert Briefs::Totals.hundred?([30, 20, 20, 15, 15])
    refute Briefs::Totals.hundred?([30, 20, 20, 15, 14]), "99"
    refute Briefs::Totals.hundred?([30, 20, 20, 15, 16]), "101"
    refute Briefs::Totals.hundred?([50, 50.0]), "a float is not a whole percent"
    refute Briefs::Totals.hundred?([Rational(100, 1)]), "a rational is not an Integer"
    refute Briefs::Totals.hundred?([50, nil, 50]), "a blank row is not 0"
    refute Briefs::Totals.hundred?(%w[50 50]), "strings are not numbers"
    refute Briefs::Totals.hundred?([-10, 110]), "a negative share cannot balance an oversized one"
    refute Briefs::Totals.hundred?([]), "an empty list is not 100"
    refute Briefs::Totals.hundred?(nil)
  end

  test "Totals.threshold? accepts 0 to 100 inclusive and nothing else" do
    [0, 0.0, 62.5, 100, 100.0].each { |v| assert Briefs::Totals.threshold?(v), v.inspect }
    [-0.1, 100.1, nil, "60", Float::NAN].each { |v| refute Briefs::Totals.threshold?(v), v.inspect }
  end

  # --- activities through the service ------------------------------------------------------------
  test "activity shares: 99 and 101 are named at completion, exactly 100 passes" do
    job = briefed_job(complete: false)
    { [30, 20, 20, 15, 14] => "99%", [30, 20, 20, 15, 16] => "101%" }.each do |shares, named|
      save_step!(job, "2", activities(shares))
      msg = problems(job, 2).grep(/time shares/)
      assert_equal 1, msg.size, shares.inspect
      assert_includes msg.first, named
    end
    save_step!(job, "2", activities([30, 20, 20, 15, 15]))
    assert_empty problems(job, 2), "control: exactly 100"
  end

  test "malformed shares are refused at save, never read as 0" do
    job = briefed_job(complete: false)
    before = job.activities.pluck(:share_percent)
    ["abc", "-5", "50.5", "50,0", "1e2", "0x20", "101", "99999999999999999999"].each do |bad|
      params = activities([bad, 20, 20, 15, 15])
      result = run_step(job, "2", params)
      refute result.ok?, "#{bad.inspect} was accepted"
      assert result.errors.any? { |e| e.include?("Activity 1") }, "#{bad.inspect}: the row is named"
      assert_equal before, job.reload.activities.pluck(:share_percent), "#{bad.inspect}: nothing saved"
    end
    params = activities([" 30 ", 20, 20, 15, 15])
    assert run_step(job, "2", params).ok?, "control: surrounding spaces are not an error"
  end

  test "a blank share on a filled activity row is refused, a fully blank row is skipped" do
    job = briefed_job(complete: false)
    params = activities([30, 20, 20, 15, 15])
    params[:activities]["0"][:share_percent] = ""
    refute run_step(job, "2", params).ok?
    params = activities([30, 20, 20, 15, 15])
    params[:activities]["5"] = { description: "", output: "", share_percent: "" }
    assert run_step(job, "2", params).ok?, "control: an empty slot is ignored"
    assert_equal 5, job.activities.count
  end

  test "activity count 5-8: 4 and 9 are refused at completion, 5 and 8 pass" do
    job = briefed_job(complete: false)
    { [25, 25, 25, 25] => 4, [12, 11, 11, 11, 11, 11, 11, 11, 11] => 9 }.each do |shares, n|
      save_step!(job, "2", activities(shares))
      assert(problems(job, 2).any? { |m| m.include?("There are #{n} activities") }, "#{n} activities not refused")
      refute Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?, "#{n} activities completed"
    end
    [[20, 20, 20, 20, 20], [13, 13, 13, 13, 12, 12, 12, 12]].each do |shares|
      save_step!(job, "2", activities(shares))
      assert_empty problems(job, 2), "control: #{shares.size} activities"
    end
  end

  # --- requirements and knockouts ----------------------------------------------------------------
  test "knockout count 2-3: 0, 1 and 4 are refused at completion, 2 and 3 pass" do
    job = briefed_job(complete: false)
    { [] => 0, ["Bersedia shift?"] => 1, ["A?", "B?", "C?", "D?"] => 4 }.each do |kos, n|
      save_step!(job, "3", step3_params(knockouts: kos))
      assert(problems(job, 3).any? { |m| m.include?("There are #{n} knockout questions") }, "#{n} knockouts not refused")
    end
    [["A?", "B?"], ["A?", "B?", "C?"]].each do |kos|
      save_step!(job, "3", step3_params(knockouts: kos))
      assert_empty problems(job, 3), "control: #{kos.size} knockouts"
      assert_equal kos, job.knockout_questions.order(:position).pluck(:text)
    end
  end

  test "a knockout question on a sebaiknya or nilai tambah line is refused (rule 16)" do
    job = briefed_job(complete: false)
    texts = job.knockout_questions.order(:position).pluck(:text)
    %w[sebaiknya nilai_tambah].each do |tier|
      params = step3_params
      row = params[:requirements].values.find { |r| r[:tier] == tier }
      row[:knockout] = "Pertanyaan pada #{tier}?"
      result = run_step(job, "3", params)
      refute result.ok?, "#{tier} accepted a knockout question"
      assert result.errors.any? { |e| e.include?("only for a must-have requirement") }
      assert_equal texts, job.reload.knockout_questions.order(:position).pluck(:text)
    end
  end

  test "sebaiknya weights: 99 and 101 refused at completion, 100 passes, malformed refused at save" do
    job = briefed_job(complete: false)
    { [60, 39] => "99%", [60, 41] => "101%" }.each do |weights, named|
      save_step!(job, "3", step3_params(weights:))
      assert(problems(job, 3).any? { |m| m.include?("should-have weights add up to #{named}") }, weights.inspect)
    end
    save_step!(job, "3", step3_params(weights: [60, 40]))
    assert_empty problems(job, 3)
    ["abc", "-1", "40.5", "101"].each do |bad|
      params = step3_params
      params[:requirements].values.find { |r| r[:tier] == "sebaiknya" }[:weight] = bad
      refute run_step(job, "3", params).ok?, "weight #{bad.inspect} accepted"
    end
  end

  # --- stage plan --------------------------------------------------------------------------------
  test "stage weights 99 / 101 and every malformed threshold are refused" do
    job = briefed_job(complete: false)
    w = Briefs::StagePlan.default_weights(3)
    save_step!(job, "4", step4_params(weights: w.merge("S5" => w["S5"] - 1)))
    assert(problems(job, 4).any? { |m| m.include?("stage weights add up to 99%") })
    save_step!(job, "4", step4_params(weights: w.merge("S5" => w["S5"] + 1)))
    assert(problems(job, 4).any? { |m| m.include?("stage weights add up to 101%") })
    save_step!(job, "4", step4_params)
    assert_empty problems(job, 4), "control"

    ["-1", "100,5", "62,55", "abc", "1e1", "60%"].each do |bad|
      refute run_step(job, "4", step4_params(threshold: bad)).ok?, "threshold #{bad.inspect} accepted"
    end
    save_step!(job, "4", step4_params(threshold: ""))
    assert(problems(job, 4).any? { |m| m.include?("pass score") }, "a blank threshold is not 0")
    { "0" => 0.0, "100" => 100.0, "62,5" => 62.5, "62.5" => 62.5 }.each do |typed, stored|
      save_step!(job, "4", step4_params(threshold: typed))
      assert_equal stored, job.reload.stage_plan.dig("S1", "threshold"), typed
    end
  end

  # --- money ---------------------------------------------------------------------------------------
  test "salary is integer rupiah: display forms accepted, decimals and min > max refused" do
    job = briefed_job(complete: false)
    { "5.200.000" => 5_200_000, "Rp5.200.000" => 5_200_000, "Rp 5.200.000" => 5_200_000, "5200000" => 5_200_000 }.each do |typed, value|
      save_step!(job, "3", step3_params.merge(salary_min: typed))
      assert_equal value, job.reload.salary_min, typed
    end
    ["5.200.000,50", "5200000,5", "5,200,000", "5.2", "5.20.000", "-5000000", "lima juta"].each do |bad|
      result = run_step(job, "3", step3_params.merge(salary_min: bad))
      refute result.ok?, "#{bad.inspect} accepted"
      assert_equal 5_200_000, job.reload.salary_min
    end
    result = run_step(job, "3", step3_params.merge(salary_min: "7.000.000", salary_max: "6.000.000"))
    refute result.ok?
    assert(result.errors.any? { |e| e.include?("is higher than the maximum") })
    assert_equal [5_200_000, 6_000_000], [job.reload.salary_min, job.salary_max]
    assert run_step(job, "3", step3_params.merge(salary_min: "6.000.000", salary_max: "6.000.000")).ok?, "control: min = max"
  end

  test "salary min > max is refused by the database too" do
    job = briefed_job(complete: false)
    refused_by_database { job.update_columns(salary_min: 9_000_000, salary_max: 1_000_000) }
  end

  test "a zero or absurd number is refused with the house sentence, never a Rails default message or an exception" do
    job = briefed_job(complete: false)
    cases = {
      ["1", step1_params.merge(headcount: "0")] => "headcount 0",
      ["1", step1_params.merge(golongan: "9")] => "golongan 9",
      ["1", step1_params.merge(golongan: "0")] => "golongan 0",
      ["1", step1_params.merge(headcount: "99999999999")] => "headcount beyond integer",
      ["3", step3_params.merge(salary_min: "0")] => "salary 0",
      ["3", step3_params.merge(salary_max: "99999999999999999999")] => "salary beyond bigint"
    }
    # Every case is run and every defect listed, so one red names all of them.
    defects = cases.filter_map do |(step, params), label|
      result = run_step(job.reload, step, params)
      if result.ok? then "#{label}: accepted"
      elsif result.errors.grep(ENGLISH).any? then "#{label}: Rails default message shown to the user: #{result.errors.inspect}"
      elsif result.errors.grep(ENGLISH_ATTRIBUTE).any? then "#{label}: Rails attribute name shown to the user: #{result.errors.inspect}"
      end
    rescue StandardError => e
      "#{label}: #{e.class}: #{e.message[0, 160]}"
    end
    assert_empty defects, defects.join("\n")
  end

  # --- multi-value placements ----------------------------------------------------------------------
  test "placements are a distinct ordered list; blanks dropped; location derived from them" do
    job = briefed_job(complete: false)
    save_step!(job, "3", step3_params.merge(placements: ["Bekasi", "", "  Karawang ", "Bekasi", "Cikarang"]))
    assert_equal %w[Bekasi Karawang Cikarang], job.reload.placements
    assert_equal "Bekasi, Karawang, Cikarang", job.location
    save_step!(job, "3", step3_params.merge(placements: ["", ""]))
    assert_equal [], job.reload.placements
    assert_nil job.location
    assert(problems(job, 3).any? { |m| m.include?("placement") }, "no placement must block completion")
  end
end
