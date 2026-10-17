require "test_helper"
require_relative "bank_scoring_pass_helper"

# Independent test pass, competency test scoring slice C: the score arithmetic, the vacancy average
# (the line between "the HR Manager confirms" and "the AI rating counts") and what the board offers
# on each side of it. The draw is 5 multiple-choice and 3 written questions; every score below is
# worked by hand in the assertion message.
class ScoreBoardPassTest < ActionDispatch::IntegrationTest
  include BankScoringPassHelper

  setup { setup_bank! }

  test "equal weight per drawn question; the HR Manager's rating replaces the AI's; unanswered written is 0" do
    draft = pass_applicant!("sum@contoh.example", mc_right: 3)
    pass_ai_rate!(draft, CapturingClient.new({ rating: 1 }, { rating: 3 }, { rating: 5 }))
    assert_equal 56.25, ApplicationDrafts::Score.call(draft.reload).value, "(3 x 100 + 0 + 50 + 100) / 8"
    low = written_answers(draft).find { |a| a.ai_rating == 1 }
    low.update_columns(review_rating: 5, reviewed_by_id: @manager.id, reviewed_at: Time.current)
    result = ApplicationDrafts::Score.call(draft.reload)
    assert_equal 68.75, result.value, "(3 x 100 + 100 + 50 + 100) / 8: the HR rating 5 wins over the AI rating 1"
    refute result.reviewed?, "two written answers still carry only the AI rating"

    blank = pass_applicant!("blank@contoh.example", mc_right: 0, written: ->(i) { i == 2 ? "" : "I count twice." })
    pass_ai_rate!(blank, CapturingClient.new({ rating: 5 }))
    result = ApplicationDrafts::Score.call(blank.reload)
    assert_equal [25.0, 2], [result.value, result.written_count], "(0 + 100 + 100 + 0 unanswered) / 8"
  end

  test "the average counts only complete scores; an incomplete applicant is never on the AI side" do
    top = pass_applicant!("top@contoh.example", mc_right: 5)
    low = pass_applicant!("low@contoh.example", mc_right: 0)
    open = pass_applicant!("open@contoh.example", mc_right: 5)
    pass_ai_rate!(top, CapturingClient.new({ rating: 5 }))
    pass_ai_rate!(low, CapturingClient.new({ rating: 1 }))
    pass_ai_rate!(open, CapturingClient.new(Screening::Errors::Transient.new("transient", "timeout")))
    [top, low, open].each { |d| pass_s1!(d) }
    board = ApplicationDrafts::Board.new(@job)
    assert_nil ApplicationDrafts::Score.call(open.reload).value
    assert_equal 50.0, board.average, "(100 + 0) / 2; the incomplete applicant is left out"
    refute board.below_average?(open), "an incomplete score is never 'below average'"
    error = assert_raises(ApplicationDrafts::RecordScore::Refused) { ApplicationDrafts::RecordScore.call(draft: open, reviewer: @manager, mode: "ai") }
    # Rule changed 17 Oct 2026: the refusal now names the missing usable AI rating (was matched on
    # /average/ before). The point stands: an incomplete applicant is never on the AI side.
    assert_match(/no usable AI rating/, error.message)

    pass_ai_rate!(open, CapturingClient.new({ rating: 5 }))
    assert_in_delta 66.67, ApplicationDrafts::Board.new(@job).average, 0.01, "control: once complete it counts, (100 + 0 + 100) / 3"
  end

  test "a tie between every complete applicant: nobody is below the average, the AI mode is refused for all" do
    a = pass_applicant!("same1@contoh.example", mc_right: 2)
    b = pass_applicant!("same2@contoh.example", mc_right: 2)
    [a, b].each { |d| pass_ai_rate!(d, CapturingClient.new({ rating: 3 })) }
    [a, b].each { |d| pass_s1!(d) }
    board = ApplicationDrafts::Board.new(@job)
    assert_equal [43.75, 43.75], [a, b].map { |d| ApplicationDrafts::Score.call(d.reload).value }, "(200 + 3 x 50) / 8"
    assert(board.rows.all?(&:needs_review))
    [a, b].each do |d|
      assert_raises(ApplicationDrafts::RecordScore::Refused) { ApplicationDrafts::RecordScore.call(draft: d, reviewer: @manager, mode: "ai") }
      assert_equal [0, 0], s2_records(d)
    end
  end

  test "a strong applicant without written answers can be recorded through the button the board offers" do
    strong = pass_applicant!("mconly@contoh.example", mc_right: 5, written: ->(_) { "" }) # 500 / 8 = 62.5
    weak = pass_applicant!("weak@contoh.example", mc_right: 0)
    pass_ai_rate!(weak, CapturingClient.new({ rating: 1 }))
    pass_ai_rate!(strong, CapturingClient.new({ rating: 1 }))
    [strong, weak].each { |d| pass_s1!(d) }
    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    form = Nokogiri::HTML(response.body).css("form.bank-scoring-form").find { |f| f["action"].end_with?("/#{strong.id}/record") }
    assert form, "the board offers a form for the strong applicant"
    fields = form.css("input[type=hidden], textarea, select").to_h { |f| [f["name"], f["value"].to_s] }
    button = form.at("button[type=submit]")
    assert button, "the board offers a button to record the strong applicant"
    post form["action"], params: fields.merge(button["name"] => button["value"])
    assert_redirected_to staff_job_bank_scorings_path(@job),
                         "the hidden mode is #{fields['mode'].inspect}; the service answered: #{css_select('.alert, .invalid-feedback, [role=alert]').map(&:text).join(' ').squish}"
  end

  test "after an AI failure the board lets the HR Manager rate the written answers by hand, as its message says" do
    draft = pass_applicant!("byhand@contoh.example", mc_right: 2)
    pass_ai_rate!(draft, CapturingClient.new(Screening::Errors::Transient.new("transient", "timeout")))
    pass_s1!(draft)
    assert_match(/Rate the rest by hand/, draft.reload.ai_error)
    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    card = Nokogiri::HTML(response.body).css("form.bank-scoring-form").find { |f| f["action"].end_with?("/#{draft.id}/record") }
    assert card
    assert_equal 3, card.css("select[name^='ratings[']").size, "the message says 'rate the rest by hand' but the card offers no rating to give"
    assert card.at("button[type=submit]"), "and no button to record"
  end

  test "an applicant eliminated at S1 is left out of the vacancy average" do
    kept = pass_applicant!("kept@contoh.example", mc_right: 1)
    mid = pass_applicant!("mid@contoh.example", mc_right: 3)
    gone = pass_applicant!("gone@contoh.example", mc_right: 5)
    pass_ai_rate!(kept, CapturingClient.new({ rating: 2 }))
    pass_ai_rate!(mid, CapturingClient.new({ rating: 3 }))
    pass_ai_rate!(gone, CapturingClient.new({ rating: 5 }))
    # kept (100 + 3 x 25) / 8 = 21.875; mid (300 + 3 x 50) / 8 = 56.25; gone 100.
    assert_in_delta 59.38, ApplicationDrafts::Board.new(@job).average, 0.01, "control: before the elimination all three count"
    s1 = s1_of(gone.job_application)
    s1.update!(attendance: "attended") if s1.attendance == "pending"
    Decision.create!(participation: s1, outcome: "eliminate", basis: "manual", reason_code: "pass_check", note: "Invented.", decided_by_id: @manager.id, decided_at: Time.current)
    assert TechnicalTests.s1_eliminated?(gone.job_application)
    # Rule changed 17 Oct 2026: before, gone still counted and the line stayed at 59.38. Now it is
    # (21.875 + 56.25) / 2 = 39.06, and kept is below it.
    board = ApplicationDrafts::Board.new(@job)
    assert_in_delta 39.06, board.average, 0.01, "was 59.38 under the old rule"
    assert board.below_average?(kept)
    refute board.below_average?(mid)
  end
end
