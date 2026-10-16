require "test_helper"

# AI Builder Cup step 08: the AI places the candidate in the salary band (a position, never rupiah),
# the code computes the rupiah, the owner agrees a figure.
class SalaryTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  Fake = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "uji-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = technical_test_job(open_gate: false)
    @job.update_columns(salary_min: 5_200_000, salary_max: 6_000_000)
    @application, = applicant!(@job, name: "Dewi Lestari", expected_salary_min: 7_000_000, expected_salary_max: 7_500_000)
    @hr = staff_user("hr_pic")
    @owner = staff_user("owner")
  end

  def pass_every_stage!
    Screening::Config.stub(:enabled?, false) do
      loop do
        step = @application.reload.participations.select { |p| Progression.step?(p) && p.progression_choice.nil? }
                           .min_by { |p| Progression.order_of(p.stage) }
        step.stage.score_source == "scorecard" && @job.competencies.exists?(stage_code: step.stage.code) &&
          Progression::ScoreInterview.call(participation: step, actor: @hr, attendance: "attended",
                                           ratings: @job.competencies.where(stage_code: step.stage.code).to_h { |c| [c.id.to_s, "4"] })
        Progression::Choose.call(participation: step, actor: @hr, choice: "lanjut", seen_recommendation_id: StageRecommendation.latest_for(step)&.id)
        break if Progression::Salary.ready?(@application.reload)
      end
    end
  end

  def recommend(position)
    fake = Fake.new({ position:, summary: "Posisi tengah.", factors: ["Wawancara kuat"] }.to_json)
    rec = Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake) { Progression::Salary.recommend(application: @application, actor: @hr) }
    end
    [rec, fake.seen]
  end

  test "the rupiah is computed from the position, to the nearest Rp50.000, never outside the band" do
    assert_equal 5_200_000, Progression::Salary.amount_for(@job, 0)
    assert_equal 6_000_000, Progression::Salary.amount_for(@job, 1)
    assert_equal 5_600_000, Progression::Salary.amount_for(@job, 0.5)
    assert_equal 5_450_000, Progression::Salary.amount_for(@job, 0.32) # 5.456.000 -> 5.450.000
    assert_equal 6_000_000, Progression::Salary.amount_for(@job, 1.2.clamp(0, 1))
  end

  test "only after the last stage's Lanjut; the AI never sees a rupiah figure, the expectation or the name" do
    refute Progression::Salary.ready?(@application)
    pass_every_stage!
    assert Progression::Salary.ready?(@application)

    rec, sent = recommend(0.5)
    assert rec.ready?
    assert_equal [0.5, 5_600_000], [rec.position.to_f, rec.amount]
    ["5200000", "6000000", "5.200.000", "7000000", "7500000", "Dewi", "Lestari"].each { |v| refute_includes sent, v }
  end

  test "the owner agrees; a note is needed off the AI's figure or outside the band; others are refused" do
    pass_every_stage!
    rec, = recommend(0.5)
    agree = ->(**kw) { Progression::Salary.agree(application: @application, seen_recommendation_id: rec.id, note: nil, **kw) }

    assert_raises(Progression::Salary::Refused) { agree.(actor: @hr, amount: "5.600.000") }
    assert_equal :note, assert_raises(Progression::Salary::Refused) { agree.(actor: @owner, amount: "5.700.000") }.field
    assert_equal :note, assert_raises(Progression::Salary::Refused) { agree.(actor: @owner, amount: "6.500.000") }.field

    assert_equal 5_600_000, agree.(actor: @owner, amount: "Rp5.600.000").agreed_amount
    outside = agree.(actor: @owner, amount: "6.500.000", note: "Kandidat langka; disetujui direksi.")
    assert outside.outside_band
    assert_equal 6_500_000, SalaryAgreement.latest_for(@application).agreed_amount

    newer, = recommend(0.2)
    assert newer
    assert_match(/has been refreshed/, assert_raises(Progression::Salary::Refused) { agree.(actor: @owner, amount: rec.amount) }.message)
    error = refused_by_database do
      SalaryAgreement.create!(job_application: @application, agreed_amount: 1, outside_band: false, decided_by: @hr, created_at: Time.current)
    end
    assert_match(/only the owner/, error.message)
  end
end
