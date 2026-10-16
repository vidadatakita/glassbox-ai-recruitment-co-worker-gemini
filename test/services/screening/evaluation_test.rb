require "test_helper"

# Plan task A9: the agreement and cost check. Risks hunted: a harness that agrees with itself (it
# must go below 100% when the answers drift), one that leaks the invented applicant's name or
# contacts into the request (it must send what a real run sends: evidence sections, redacted), one
# that trusts an invented quote, and one that lets a failed call abort the whole measurement.
class Screening::EvaluationTest < ActiveSupport::TestCase
  def cases = @cases ||= Screening::Evaluation.demo_cases

  def reply(criteria, model: "eval-model", tokens: [1000, 200, 300])
    Screening::AiClient::Reply.new(model:, text: JSON.generate({ criteria:, protected_attribute_seen: false, protected_attribute_categories: [] }),
                                   input_tokens: tokens[0], output_tokens: tokens[1], thinking_tokens: tokens[2])
  end

  def hand_criteria(kase)
    kase.rubric.criteria.map do |c|
      judgement, quote = kase.hand.fetch(kase.codes.fetch(c.key))
      { id: c.key, quote:, judgement: }
    end
  end

  test "dry run with the hand scores: 25 invented CVs, 100 judgements, full agreement, every quote verified" do
    report = Screening::Evaluation.call(cases:, judge: Screening::Evaluation.hand_judge)
    assert_equal 25, report.calls.size
    assert_equal 25, report.answered
    assert_equal 100, report.rows.size
    assert_equal 25, report.must.size
    assert_equal 1.0, report.share(report.rows, &:agree?)
    assert_equal 1.0, report.share(report.outcomes, &:agree?)
    assert(report.positives.all?(&:verified), "the hand quotes are verbatim CV lines")
    assert_empty report.largest_disagreements
    assert_includes report.to_markdown, "| All judgements, exact | 100.0% | 100 |"
  end

  test "drifting answers lower the agreement, an invented quote is unverified, the largest disagreement is listed first" do
    judge = lambda do |_content, kase|
      criteria = hand_criteria(kase).map do |c|
        tier = kase.rubric.by_key.fetch(c[:id]).tier
        next c.merge(judgement: (c[:judgement].to_i - 1).clamp(0, 3).to_s) if tier == "sebaiknya" && c[:judgement].to_i >= 2
        next c.merge(quote: "Chartered accountant since 2001") if kase.key == "ACC-01" && tier == "wajib"

        c
      end
      reply(criteria)
    end
    report = Screening::Evaluation.call(cases:, judge:, threads: 2)
    exact = report.share(report.ratings, &:agree?)
    assert_operator exact, :<, 1.0, "a harness that cannot go below 100% measures nothing"
    assert_equal 1.0, report.share(report.ratings, &:within_one?), "every drift is one point"
    assert_equal 1.0, report.share(report.must, &:agree?), "the must-have judgements did not move"
    planted = report.rows.find { |r| r.cv_id == "ACC-01" && r.code == "M1" }
    assert_equal false, planted.verified, "a quote that is not in the CV is not evidence"
    assert_operator report.share(report.positives, &:verified), :<, 1.0
    assert_equal 1, report.largest_disagreements.first.distance
    assert_operator report.outcomes.count { |o| o.ai_score < o.hand_score }, :>, 0, "lower ratings give lower S1 scores"
    assert_includes report.to_csv.lines.first, "ai_quote_verified"
  end

  test "the request is what a real run sends: evidence sections only, redacted, no name, e-mail or phone of the invented applicant" do
    sent = Queue.new
    judge = lambda do |content, kase|
      sent << [content, kase]
      reply(hand_criteria(kase))
    end
    Screening::Evaluation.call(cases:, judge:)
    assert_equal 25, sent.size
    until sent.empty?
      content, kase = sent.pop
      assert_includes content, "<requirements>"
      assert_includes content, "WORK EXPERIENCE"
      refute_includes content, kase.name, "#{kase.key}: the name reached the request"
      refute_match(/@applicant\.example|0812-7\d{3}-\d{4}|Date of Birth|Gender :/, content, "#{kase.key}: personal data reached the request")
    end
  end

  test "a failed call is recorded on its CV; the other CVs are still measured, and the cost line uses the given prices" do
    judge = lambda do |_content, kase|
      raise Screening::Errors::Transient.new("api_error", "HTTP 503") if kase.key == "ADM-01"

      reply(hand_criteria(kase), tokens: [2000, 400, 600])
    end
    report = Screening::Evaluation.call(cases:, judge:)
    assert_equal 24, report.answered
    assert_match(/Transient/, report.calls.find { |c| c.cv_id == "ADM-01" }.error)
    assert_equal 96, report.rows.size
    # 100 CVs x (2000 input x $1 + (400 output + 600 thinking) x $10) per 1M tokens = $1.20.
    assert_in_delta 1.2, report.cost_per_100({ input: 1.0, output: 10.0 }), 1e-9
    markdown = report.to_markdown(prices: { input: 1.0, output: 10.0 })
    assert_includes markdown, "24 of 25 CVs answered"
    assert_includes markdown, "| 1.20 |"
    assert_includes markdown, "ADM-01: Transient"
    assert_nil report.cost_per_100(nil), "no price given, no cost line"
  end
end
