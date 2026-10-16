require "test_helper"

# The report's quote partial. Since 16 Oct a criterion may rest on up to three passages, stored
# joined by Screening::QuoteCheck::SEPARATOR: each is shown as its own quote, and the one
# "unverified" mark covers them all. Masking (report_ai) is the board's; a pass-through stands in.
class ScreeningReportQuoteTest < ActionView::TestCase
  helper ScreeningReportHelper

  Board = Struct.new(:unused) { def ai_text(_row, text) = text }

  setup { @board = Board.new }

  def quote_html(quote, verified) = render(partial: "staff/screening_reports/quote", locals: { quote:, verified:, row: nil })

  test "two passages are two quotes, marked once when the check did not find them all" do
    quote_html("Posts daily journals#{Screening::QuoteCheck::SEPARATOR}Prepares the bank reconciliation", false)
    assert_equal ["Posts daily journals", "Prepares the bank reconciliation"], css_select("q.report-quote").map(&:text)
    assert_equal 1, css_select(".portal-state--danger").size
  end

  test "one passage stays one quote; an erased quote shows none" do
    quote_html("Leads a team of four accounting staff", true)
    assert_equal ["Leads a team of four accounting staff"], css_select("q.report-quote").map(&:text)
    assert_empty css_select(".portal-state--danger")
    assert_includes quote_html(nil, true), "No quote"
  end
end
