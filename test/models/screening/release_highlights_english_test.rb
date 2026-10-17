require "test_helper"

# The release screen's family and worship hints mark English CV lines too (17 Oct 2026: every demo CV
# is English, and these two categories only knew Indonesian words). Hints are display-only.
class Screening::ReleaseHighlightsEnglishTest < ActiveSupport::TestCase
  def categories(line) = Screening::ReleaseHighlights.hint_spans(line, 0).map(&:category).uniq

  test "English family and worship words are hinted, Indonesian ones still are" do
    assert_includes categories("Took a break to care for my children and my husband."), "family"
    assert_includes categories("Mother of two, back at work since 2022."), "family"
    assert_includes categories("Treasurer of the church youth group."), "worship"
    assert_includes categories("Led the weekly Bible study at the office."), "worship"
    assert_includes categories("Sebagai istri dan ibu dua anak."), "family"
    assert_includes categories("Pengurus masjid kampung."), "worship"
  end

  test "control: a plain evidence line gets no family or worship hint" do
    line = "Prepared the monthly closing and reconciled 120 supplier accounts."
    assert_empty categories(line) & %w[family worship]
    refute_includes categories("Worked with a wifi vendor and a temperature logger."), "family", "no match inside a longer word"
  end
end
