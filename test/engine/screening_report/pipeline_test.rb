require "test_helper"
require_relative "engine08_support"

# Engine 08 through the REAL S1 pipeline (FakeGemini at the HTTP boundary): the
# expected salary (D62 h5) and the domicile city never reach the outgoing request body and never
# change a score, and the report block lands on the result. This file depends on the D51 release
# gate (screen_and_release!, another lane): a red here that also shows in test/engine/screening is
# that lane's, not feature 08's.
class Engine08PipelineTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory
  include ReportFactory

  setup do
    set_retention
    publish_consent
    @job = screening_job
  end

  def screen(name, salary:)
    fake = ScreeningFactory::FakeGemini.new
    participation = nil
    with_ai(fake) do
      fake.push(gemini_message(nil, text: JSON.generate({ criteria: criteria_for(@job), protected_attribute_seen: false,
                                                          protected_attribute_categories: [], report: report_block })))
      participation = apply_with_cv!(@job, name:)
      participation.job_application.update_columns(expected_salary_min: salary.first, expected_salary_max: salary.last,
                                                   domicile_city: "Kotauji Selatan")
      screen_and_release!
    end
    [participation.reload, fake]
  end

  test "expected salary and domicile city are never in the Gemini request body; the CV is (control); scores do not move with salary" do
    p1, fake1 = screen("Calon Gaji Rendah", salary: [7_654_321, 8_765_432])
    p2, fake2 = screen("Calon Gaji Tinggi", salary: [47_654_321, 98_765_432])
    [fake1, fake2].each do |fake|
      assert_equal 1, fake.bodies.size, "exactly one request per applicant"
      body = fake.bodies.first
      assert_includes body, "Admin Gudang di PT Logistik Makmur", "control: the CV evidence is in the body"
      %w[7654321 7.654.321 8765432 8.765.432 47654321 98765432 Kotauji].each { |v| refute body.include?(v), "#{v} reached the AI" }
    end
    r1 = ScreeningResult.current_for(p1.id).first
    r2 = ScreeningResult.current_for(p2.id).first
    assert_equal r1.score, r2.score, "a 6x higher expected salary changed the S1 score"
    assert_equal p1.current_score.to_f, p2.current_score.to_f
    assert_equal "pertimbangkan", r1.label_proposal
    assert r1.last_position["verified"]
    refute r1.narratives["blind_spots"].first["verified"], "the invented quote is marked"
  end

  test "the S1 request carries the optional report schema without over_qualified and the prompt version .3 or later" do
    _p, fake = screen("Calon Skema", salary: [5_000_000, 6_000_000])
    req = fake.parsed_bodies.first
    schema = req.to_s
    assert_includes schema, "label_proposal"
    refute_includes schema, "over_qualified"
    assert_equal "s1-2026-10-16.2", Screening::PROMPT_VERSION
  end
end
