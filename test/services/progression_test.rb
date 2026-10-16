require "test_helper"

# AI Builder Cup step 06: the AI recommends Lanjut / Tidak Lanjut with reasons; the HR PIC scores
# Interview 1 and chooses Lanjut / Rekomendasi AI / Tidak Lanjut; the choice moves the candidate.
class ProgressionTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  Fake = Struct.new(:answers, :seen) do
    def generate(system:, schema:, content:)
      (self.seen ||= []) << content
      Screening::AiClient::Reply.new(model: "uji-model", text: answers.shift.to_json, input_tokens: 1, output_tokens: 1)
    end
  end

  ADVICE = { advice: "tidak_lanjut", ai_score: 40, summary: "Bukti belum cukup.", strengths: ["Node.js"],
             gaps: ["Tes belum dikerjakan"], risks: [], change_view: "Nilai tes di atas ambang." }.freeze

  setup do
    @job = technical_test_job(open_gate: false)
    @application, = applicant!(@job, name: "Dewi Lestari", phone: "081234567890")
    @s1 = s1_of(@application)
    @hr = staff_user("hr_pic")
  end

  def with_ai(*answers, &)
    fake = Fake.new(answers.map(&:dup))
    Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, fake) { yield fake } }
  end

  def choose(choice, rec: StageRecommendation.latest_for(@s1), note: nil, participation: @s1, actor: @hr)
    Progression::Choose.call(participation:, actor:, choice:, seen_recommendation_id: rec&.id, note:)
  end

  def s3 = @application.participations.joins(:stage).find_by(stages: { code: "S3" })

  test "Lanjut on a draft gate opens it, aligns both gate decisions by hand with the note, and enters S3" do
    choice = choose("lanjut")

    assert_equal %w[open open], @job.stages.where(code: %w[S1 S2]).order(:code).pluck(:status)
    [@s1, s2_of(@application)].each do |p|
      decision = p.reload.current_decision
      assert_equal %w[pass manual progression_choice], [decision.outcome, decision.basis, decision.reason_code]
      assert_equal @hr.id, decision.decided_by_id
    end
    assert_equal "pending", s3.attendance
    assert_equal ["lanjut", "lanjut", @hr.id], [choice.choice, choice.direction, choice.actor_id]
  end

  test "the candidate's own page shows a step as passed once the HR PIC chose Lanjut, before the stage closes" do
    choose("lanjut")
    steps = CandidateStatus.new(@application.reload).steps
    gate = steps.find { |step| step.label.start_with?(CandidateStatus::GATE_LABEL) }
    assert_equal ["#{CandidateStatus::GATE_LABEL}: passed", :done], [gate.label, gate.state]
    assert_equal :current, steps.find { |step| step.label.start_with?("Interview 1") }.state
    refute_match(/complete/i, CandidateStatus.new(@application).next_line)
  end

  test "Tidak Lanjut needs a note, at the note field; with it the gate is eliminated and nobody enters S3" do
    error = assert_raises(Progression::Choose::Refused) { choose("tidak_lanjut", note: "  ") }
    assert_equal :note, error.field

    choose("tidak_lanjut", note: "Pengalaman Node.js belum cukup.")
    assert_equal "eliminate", @s1.reload.current_decision.outcome
    assert_equal "Pengalaman Node.js belum cukup.", @s1.current_decision.note
    assert_nil s3
  end

  test "Rekomendasi AI follows the recommendation on screen; stale, missing, and departures without a note are refused" do
    assert_match(/No AI advice is available yet/, assert_raises(Progression::Choose::Refused) { choose("ikut_ai") }.message)

    shown = with_ai(ADVICE, ADVICE.merge(advice: "lanjut")) do
      first = Progression::Recommend.call(participation: @s1, actor: @hr)
      Progression::Recommend.call(participation: @s1, actor: @hr)
      first
    end
    assert_match(/has been refreshed/, assert_raises(Progression::Choose::Refused) { choose("ikut_ai", rec: shown) }.message)

    latest = StageRecommendation.latest_for(@s1)
    assert_equal "lanjut", latest.advice
    error = assert_raises(Progression::Choose::Refused) { choose("tidak_lanjut", rec: latest) }
    assert_equal :note, error.field

    choice = choose("ikut_ai", rec: latest)
    assert_equal ["ikut_ai", "lanjut", latest.id], [choice.choice, choice.direction, choice.stage_recommendation_id]
    assert s3, "following the AI's Lanjut moves the candidate on"
  end

  test "only the HR PIC chooses, once, on the step's S1 row; the database refuses another role too" do
    assert_raises(Progression::Choose::Refused) { choose("lanjut", actor: staff_user("consultant")) }
    assert_raises(Progression::Choose::Refused) { choose("lanjut", participation: s2_of(@application)) }
    choose("lanjut")
    assert_match(/already recorded/, assert_raises(Progression::Choose::Refused) { choose("lanjut") }.message)

    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) do
        ProgressionChoice.create!(participation: s2_of(@application), choice: "lanjut", direction: "lanjut",
                                  actor: staff_user("consultant"), created_at: Time.current)
      end
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { ProgressionChoice.last.update!(note: "ubah") }
  end

  test "the recommendation sends structured evidence only: no name, contacts or CV text; failures are recorded, not raised" do
    sent = with_ai(ADVICE) do |fake|
      rec = Progression::Recommend.call(participation: @s1, actor: @hr)
      assert rec.ready?
      assert_equal ["tidak_lanjut", 40], [rec.advice, rec.ai_score.to_i]
      fake.seen.first
    end
    data = JSON.parse(sent)
    assert_equal @job.title, data["job_title"]
    ["Dewi", "Lestari", "081234567890", @application.candidate.email].each { |value| refute_includes sent, value }

    Screening::Config.stub(:enabled?, false) do
      assert_no_difference -> { StageRecommendation.count }, "without an AI provider nothing is asked and nothing recorded" do
        assert_nil Progression::Recommend.call(participation: @s1, actor: @hr)
      end
    end
  end

  test "Interview 1: ratings become the stage score and threshold decision, the AI recommends, the redacted note goes along" do
    choose("lanjut")
    competency = @job.competencies.find_by!(stage_code: "S3")
    others = @job.competencies.where(stage_code: "S3").where.not(id: competency.id)
    ratings = { competency.id.to_s => "5" }.merge(others.to_h { |c| [c.id.to_s, "4"] })

    rec = with_ai(ADVICE.merge(advice: "lanjut", ai_score: 85)) do |fake|
      result = Progression::ScoreInterview.call(participation: s3, actor: @hr, attendance: "attended", ratings:,
                                                note: "Dewi menjelaskan arsitektur API dengan jelas.")
      body = fake.seen.first
      assert_includes body, "arsitektur API"
      refute_includes body, "Dewi"
      result
    end

    entry = s3.score_entries.current.last
    expected = Scoring::StageScore.from_ratings(ratings.values.map(&:to_i))
    assert_equal expected, entry.value
    assert_equal "threshold", s3.current_decision.basis
    assert_equal "open", s3.stage.reload.status, "the first interview score opens Interview 1"
    assert rec.ready?
    assert_match(/already recorded/, assert_raises(Progression::ScoreInterview::Refused) {
      Progression::ScoreInterview.call(participation: s3, actor: @hr, attendance: "attended", ratings:)
    }.message)
  end

  test "a step's cumulative score counts only that stage and the ones before it" do
    choose("lanjut")
    ratings = @job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, "5"] }
    Screening::Config.stub(:enabled?, false) do
      Progression::ScoreInterview.call(participation: s3, actor: @hr, attendance: "attended", ratings:)
    end
    assert_nil Progression.cumulative(@application, upto: @s1.stage), "nothing scored at the gate"
    assert_equal 100, Progression.cumulative(@application, upto: s3.stage)
  end

  test "an interview note that still shows personal data after redaction is held: nothing is sent" do
    choose("lanjut")
    ratings = @job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, "3"] }
    rec = with_ai do |fake|
      r = Progression::ScoreInterview.call(participation: s3, actor: @hr, attendance: "attended", ratings:,
                                           note: "Lhr. Bdg 01-02-1990, komunikasi baik.")
      assert_nil fake.seen, "nothing reached the AI"
      r
    end
    assert_equal "held", rec.status
  end
end
