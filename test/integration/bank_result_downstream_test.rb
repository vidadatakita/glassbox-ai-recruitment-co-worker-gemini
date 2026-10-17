require "test_helper"

# 18 Oct 2026 gap fix: the competency-test result reaches every place that reads a technical-test
# result — the step-9 AI advice evidence, the screening report block and its score cell — instead of
# "not scored yet" / "expired" (those read only the case-test review before).
class BankResultDownstreamTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include BankFlowHelpers

  test "before the score is recorded: evidence says not scored yet, the report cell awaits scoring, never expired" do
    draft = applicant!("wait@uji.example", mc_right: 4)
    pass_s1!(draft)
    s2 = TechnicalTests.participation_for(draft.job_application)
    assert_equal({ status: "competency test taken, not scored yet" }, Progression::Evidence.new(s2).send(:technical_test, s2))
    cell = travel(49.hours) do
      ScreeningReport::TestCell.of(participation: s2, decision: nil, score: nil, attempt: nil, submitted_at: draft.submitted_at, now: Time.current)
    end
    assert_equal :awaiting_review, cell.state
  end

  test "after the HR Manager records it: evidence carries score, basis, MC count and written ratings; the report shows it" do
    strong = applicant!("strong2@uji.example", mc_right: 5)
    weak = applicant!("weak2@uji.example", mc_right: 0)
    ai_rate!(strong, 5)
    ai_rate!(weak, 1)
    [strong, weak].each { |d| pass_s1!(d) }
    written = strong.answers.select { |a| a.bank_question.written? }
    ApplicationDrafts::RecordScore.call(draft: strong, reviewer: @manager, mode: "review", note: "Clear answers.", ratings: written.to_h { |a| [a.id.to_s, "4"] })

    s2 = TechnicalTests.participation_for(strong.job_application)
    facts = Progression::Evidence.new(s2).send(:technical_test, s2)
    assert_in_delta 90.6, facts[:score], 0.05
    assert_equal "confirmed by the HR Manager", facts[:basis]
    assert_equal "5 of 5 correct", facts[:multiple_choice]
    assert_equal [4], facts[:written].map { |w| w[:rating] }.uniq
    refute_match(/My plan for case|Uji strong2/, facts.to_s, "no answer text or applicant name reaches the AI")

    sign_in_as @manager
    get staff_job_screening_report_candidate_path(@job, strong.job_application)
    assert_response :success
    assert_includes response.body, "Competency test (question bank version"
    assert_includes response.body, "5 of 5 correct"
    assert_includes response.body, "90.6 / 100, confirmed by the HR Manager"
    refute_includes response.body, "The technical test has not been started"
  end
end
