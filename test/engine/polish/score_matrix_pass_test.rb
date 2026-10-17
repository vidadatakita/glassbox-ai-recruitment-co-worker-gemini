require "test_helper"

# Independent test pass (17 Oct 2026) on ScoreMatrix and staff/applications/_score_matrix.
#
# (1) Tie-out: the weighted contributions add up EXACTLY (as rationals) to Progression.cumulative, the
#     service the rest of the app shows, across several applicants, weight sets and unscored stages;
#     the rounded cumulative equals the service's rounded value.
# (2) D13 blinding: when the CV-screening (S1) row is blinded for the viewer, neither the AI score nor
#     the AI-derived outcome is printed anywhere in the card: cell text, title/aria attributes, data-
#     attributes, inline styles (the score bar width) or the cumulative. The blinded callable is passed
#     in directly, as the applicant page passes ai_result_blinded?; who is blinded is pinned by
#     test/engine/cup/calibration_blinding_test.rb and not re-tested here.
#
# Planted S1 score 73.4 is a value no other cell can show (weights, thresholds and other scores differ).
class PolishScoreMatrixPassTest < ActionView::TestCase
  include ScoringFactory
  include GateFactory

  # Three stages (S1, S2 gated; S5 interview), weights set per case, thresholds 60/60/70.
  def job_with(weights)
    job, s1, s2 = gated_job
    s5 = job.stages.find_by!(code: "S5")
    s1.update_columns(weight: weights[0])
    s2.update_columns(weight: weights[1])
    s5.update_columns(weight: weights[2])
    [job.reload, s1, s2, s5]
  end

  def applicant(job, scores)
    application = JobApplication.create!(job:)
    job.stages.each do |stage|
      next unless scores.key?(stage.code)

      p = Participation.create!(job_application: application, stage:, attendance: "attended")
      add_score(p, scores[stage.code]) if scores[stage.code]
    end
    application.reload
  end

  test "contributions sum exactly to Progression.cumulative across applicants, weights and gaps" do
    cases = [
      [[13, 25, 62], { "S1" => 73.4, "S2" => 81, "S5" => 66.7 }],
      [[13, 25, 62], { "S1" => 55.5, "S2" => nil, "S5" => 90 }], # S2 entered but unscored
      [[33, 33, 34], { "S1" => 50.1, "S2" => 50.1, "S5" => 50.1 }],
      [[10, 30, 60], { "S1" => 99.9 }],                          # only S1 reached
      [[20, 20, 60], { "S1" => 61.25, "S2" => 47.5 }]
    ]
    checked = 0
    cases.each do |weights, scores|
      job, = job_with(weights)
      application = applicant(job, scores)
      matrix = ScoreMatrix.new(application)
      service = Progression.cumulative(application)
      raw = matrix.rows.filter_map(&:contribution).sum
      exact = Scoring::Cumulative.call(application.participations.includes(:stage).to_h { |p| [p.stage.code, p.current_score] },
                                       job.stages.to_h { |s| [s.code, s.weight] })
      assert_equal exact, raw, "#{weights.inspect} #{scores.inspect}: unrounded contributions"
      assert_equal service, matrix.cumulative, "#{weights.inspect} #{scores.inspect}: rounded cumulative"
      assert_equal scores.compact.size, matrix.rows.count(&:score)
      assert(matrix.rows.reject(&:score).all? { |r| r.contribution.nil? }, "an unscored stage contributes nothing (never zero)")
      checked += 1
    end
    assert_equal cases.size, checked
  end

  # Information display, reported not failed: each share is rounded to one decimal on its own, so the
  # printed shares can differ from the printed cumulative by up to (stages x 0.05). Weights 33/33/34 at
  # 50.1 each print 16.5 + 16.5 + 17.0 = 50.0 against "Cumulative 50.1". The card header says "share
  # of", not "these add up"; this test pins the size of the drift so a change to it is noticed.
  test "printed shares may drift from the printed cumulative by at most half a step per stage" do
    job, = job_with([33, 33, 34])
    application = applicant(job, { "S1" => 50.1, "S2" => 50.1, "S5" => 50.1 })
    matrix = ScoreMatrix.new(application)
    printed = matrix.rows.filter_map { |r| r.contribution && Scoring::StageScore.round1(r.contribution) }.sum
    drift = (printed - matrix.cumulative).abs
    assert_operator drift, :<=, Rational(5, 100) * matrix.rows.count(&:contribution)
    assert_equal Rational(1, 10), drift, "observed drift on this fixture (50.0 printed vs 50.1)"
  end

  # --- D13: nothing of the blinded S1 result reaches the card ------------------------------------

  def blinded_s1 = ->(p) { p.stage.code == "S1" }
  def nobody_blinded = ->(_p) { false }

  def s1_row_fixture
    job, s1, = job_with([13, 25, 62])
    Stages::Open.call(stage: s1) if s1.reload.status == "draft"
    application = applicant(job, { "S1" => 73.4, "S2" => 81 })
    s1_part = application.participations.find_by!(stage: s1)
    decide!(s1_part, outcome: "pass")
    application
  end

  def card(application, blinded)
    html = render(partial: "staff/applications/score_matrix", locals: { matrix: ScoreMatrix.new(application, blinded:) })
    Nokogiri::HTML.fragment(html)
  end

  def s1_row(doc) = doc.css("tbody tr").find { |tr| tr.at_css("td[data-label='Stage']")&.text&.include?("CV screening") }

  test "control: unblinded, the S1 row shows its score and its result" do
    doc = card(s1_row_fixture, nobody_blinded)
    row = s1_row(doc)
    assert_includes row.text, "73.4"
    assert_includes row.text, "Passed"
  end

  test "blinded: the S1 score appears nowhere in the card, in text, attributes or styles" do
    doc = card(s1_row_fixture, blinded_s1)
    assert_includes s1_row(doc).text, "hidden"
    html = doc.to_html
    refute_includes html, "73.4", "the blinded S1 score is in the card markup"
    refute_match(/width:\s*73\.4/, html)
    doc.traverse do |node|
      next unless node.element?

      node.attribute_nodes.each { |a| refute_includes a.value, "73.4", "S1 score in #{node.name}[#{a.name}]" }
    end
  end

  # The S1 outcome next to a hidden S1 score is the AI verdict in other words: S1 decisions are the
  # AI score against the pass score (Screening::Finalize writes "pass, basis threshold"; the reviewer
  # confirms the AI advice in Screening::Review). A judge who reads "hidden · Passed" knows the AI
  # placed this CV at or above 60.
  test "blinded: the S1 row does not print the S1 result either" do
    row = s1_row(card(s1_row_fixture, blinded_s1))
    ScoreMatrix::OUTCOME_LABELS.each_value do |label|
      refute_includes row.text, label, "the blinded S1 row prints its outcome #{label.inspect}"
    end
  end

  test "blinded: the cumulative leaves S1 out and the criteria list is empty" do
    application = s1_row_fixture
    matrix = ScoreMatrix.new(application, blinded: blinded_s1)
    assert_equal Rational(81), matrix.cumulative, "only S2 (81) is visible, so the cumulative is S2 alone"
    assert_empty matrix.criteria
    assert matrix.any_hidden?
  end

  # The approver summary on the offer card is built from the same matrix: blinded, it must say
  # "hidden" for S1 and carry neither the S1 score nor an S1 cumulative.
  test "blinded: the offer approver summary carries no S1 score" do
    application = s1_row_fixture
    text = Progression::OfferAdvice.approver_summary(application, ScoreMatrix.new(application, blinded: blinded_s1))
    refute_includes text, "73.4"
    assert_match(/CV screening: hidden/, text)
    assert_includes text, "Cumulative score: 81.0."
  end
end
