require "test_helper"
require_relative "job_form_engine_support"

# Test engine, feature 03: the §2.3 coverage check per Golongan (rule 17), "one competency, one
# stage" (§2.1), the §7.1 package recommendation and its override reason (process card 3), and the
# concept-brief §3 stage ladder. Oracles are the spec tables in JobFormEngineSupport.
class JobFormCoverageAndPackageTest < ActiveSupport::TestCase
  include JobFormEngineSupport

  ALL = %w[L1 L2 L3 L4 L5 I].freeze

  test "the coverage table matches §2.3 cell by cell for every Golongan" do
    (1..8).each do |g|
      assert_equal spec_required_layers(g).sort, Briefs::Coverage.required(g).sort, "G#{g}"
      assert_empty Briefs::Coverage.missing(g, ALL), "G#{g}: all six layers cover it"
    end
  end

  test "dropping each required layer, alone, names exactly that layer; an optional layer is never named" do
    (1..8).each do |g|
      ALL.each do |layer|
        message = Briefs::Coverage.message(g, ALL - [layer])
        if spec_required_layers(g).include?(layer)
          assert message, "G#{g}: missing #{layer} not refused"
          assert_includes message, "#{layer} #{Competency::LAYERS[layer]}", "G#{g}"
          (ALL - [layer]).each { |other| refute_includes message, "#{other} #{Competency::LAYERS[other]}", "G#{g} names #{other} too" }
          assert_includes message, "G#{g}"
        else
          assert_nil message, "G#{g}: optional layer #{layer} reported missing"
        end
      end
    end
  end

  test "completion is refused per Golongan through the real service when a required layer is absent" do
    [2, 3, 4, 6].each do |g|
      package = SPEC_PACKAGES[g].first
      job = briefed_job(golongan: g, package:, complete: false)
      required = spec_required_layers(g)
      dropped = required.last
      save_step!(job, "4", step4_params(package:).merge(competencies: competencies_for(required - [dropped], package)))
      result = Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic"))
      refute result.ok?, "G#{g} completed without #{dropped}"
      assert(result.problems.any? { |p| p.step == 4 && p.message.include?("#{dropped} #{Competency::LAYERS[dropped]}") })
      refute job.reload.brief_complete?
      save_step!(job, "4", step4_params(package:).merge(competencies: competencies_for(required, package)))
      assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?, "control: G#{g} with exactly the required layers"
    end
  end

  test "a competency owned by a stage the package does not run is refused; RC can never own one" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    comps = competencies_for(ALL, 3)
    comps["0"][:stage_code] = "S4"
    save_step!(job, "4", step4_params.merge(competencies: comps))
    assert(Briefs::BriefCheck.new(job.reload).problems.any? { |p| p.message.include?("which this package does not run") })
    comps["0"][:stage_code] = "RC"
    refute run_step(job, "4", step4_params.merge(competencies: comps)).ok?, "RC accepted as an owning stage"
    refused_by_database { job.competencies.first.update_columns(stage_code: "RC") }
  end

  # §2.1 Competency: "owning stage (exactly one)"; Notes: "One competency, one stage". The row
  # model allows one stage per ROW, so the only way to assess one competency in two stages is two
  # rows with the same name. Nothing refuses that.
  test "one competency cannot be assessed in two stages (two rows, same name, different stages)" do
    job = briefed_job(golongan: 2, package: 3, complete: false)
    comps = competencies_for(ALL, 3)
    comps["6"] = comps["0"].merge(stage_code: "S5")
    comps["7"] = comps["1"].merge(name: "  #{comps['1'][:name].upcase} ", stage_code: "S2")
    result = run_step(job, "4", step4_params.merge(competencies: comps))
    refused_at_save = !result.ok?
    refused_at_completion = !Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    assert refused_at_save || refused_at_completion,
           "the brief completed with \"#{comps['0'][:name]}\" owned by S3 AND S5 (§2.1: one competency, one stage)"
  end

  test "the recommendation per Golongan is the §7.1 set" do
    (1..8).each do |g|
      assert_equal SPEC_PACKAGES[g], Briefs::PackageAdvisor.recommended(g), "G#{g}"
      (1..5).each do |p|
        assert_equal SPEC_PACKAGES[g].include?(p), Briefs::PackageAdvisor.recommended?(g, p), "G#{g} P#{p}"
      end
      assert_includes SPEC_PACKAGES[g], Briefs::PackageAdvisor.default_choice(g)
    end
    assert_raises(ArgumentError) { Briefs::PackageAdvisor.recommended(9) }
    assert_raises(ArgumentError) { Briefs::PackageAdvisor.recommended(0) }
  end

  test "an override needs a reason: nil, blank, whitespace and newline-only are refused; text passes" do
    [nil, "", "   ", "\n\t "].each do |reason|
      assert Briefs::PackageAdvisor.override_problem(4, 2, reason), "reason #{reason.inspect} accepted"
    end
    assert_nil Briefs::PackageAdvisor.override_problem(4, 2, "Klien hanya butuh daftar pelamar")
    assert_nil Briefs::PackageAdvisor.override_problem(4, 4, nil), "control: inside the set needs no reason"
  end

  test "override through the service: whitespace reason refused at completion, a real reason completes" do
    job = briefed_job(golongan: 4, package: 4, complete: false)
    save_step!(job, "4", step4_params(package: 2).merge(package_override_reason: "   "))
    assert_nil job.reload.package_override_reason, "whitespace stored as a reason"
    result = Briefs::Complete.call(job:, actor: staff_user("hr_pic"))
    refute result.ok?, "override completed without a reason"
    assert(result.problems.any? { |p| p.message.include?("Write the reason") })
    save_step!(job, "4", step4_params(package: 2).merge(package_override_reason: "Klien hanya butuh daftar pendek"))
    assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    assert_equal 2, job.reload.package
  end

  test "stages per package follow the concept-brief ladder, RC only in 4-5" do
    (1..5).each do |p|
      assert_equal SPEC_STAGES[p].sort, Briefs::StagePlan.codes(p).sort, "P#{p}"
      weights = Briefs::StagePlan.default_weights(p)
      assert_equal (SPEC_STAGES[p] - ["RC"]).sort, weights.keys.sort, "P#{p} default weights cover exactly the scored stages"
      assert_equal 100, weights.values.sum, "P#{p}"
      assert(weights.values.all?(Integer), "P#{p}")
    end
    # Concept brief §4.1: 10/20/20/20/30 re-normalised; P3 = 12.5/25/25/37.5, largest remainder.
    assert_equal({ "S1" => 10, "S2" => 20, "S3" => 20, "S4" => 20, "S5" => 30 }, Briefs::StagePlan.default_weights(4))
    assert_equal({ "S1" => 25, "S5" => 75 }, Briefs::StagePlan.default_weights(2))
    assert_equal({ "S5" => 100 }, Briefs::StagePlan.default_weights(1))
    p3 = Briefs::StagePlan.default_weights(3)
    assert_equal [25, 25], [p3["S2"], p3["S3"]]
    assert_equal 50, p3["S1"] + p3["S5"]
  end

  test "package outside 1-5 is refused at save" do
    job = briefed_job(complete: false)
    %w[0 6 -1 abc 3.5].each do |bad|
      refute run_step(job, "4", step4_params.merge(package: bad)).ok?, "package #{bad.inspect} accepted"
    end
    assert_equal 3, job.reload.package
  end
end
