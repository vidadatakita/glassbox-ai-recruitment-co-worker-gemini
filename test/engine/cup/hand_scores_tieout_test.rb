require "test_helper"
require Rails.root.join("db/seeds/demo_glassbox").to_s

# Step 7 / evaluation (A6, A9): docs/evaluation/hand-scores.csv must be the seed's HAND data, every
# hand quote must be a verbatim line of its CV, and the one planted quote must NOT be. Risk hunted:
# a hand score or quote edited in one place only, which would make the agreement check compare the
# AI against numbers the seed never showed; and a "verbatim" quote that the evidence check would
# reject, which would turn a hand score into an unverified row on the demo screen.
# Pure: no database row is written; the seed's constants and Screening::QuoteCheck only.
class CupHandScoresTieoutTest < ActiveSupport::TestCase
  CSV_PATH = Rails.root.join("docs/evaluation/hand-scores.csv")

  test "the CSV in docs/evaluation is byte-identical to what the seed generates" do
    assert File.exist?(CSV_PATH), "docs/evaluation/hand-scores.csv is missing; generate it from DemoGlassbox.hand_scores_csv"
    assert_equal DemoGlassbox.hand_scores_csv, File.read(CSV_PATH)
  end

  test "n is stated by the data: 25 applicants, 4 requirements each, 100 rows" do
    lines = DemoGlassbox.hand_scores_csv.lines(chomp: true)
    assert_equal 25, DemoGlassbox::PEOPLE.size
    assert_equal '"cv_id","vacancy","tier","requirement_code","requirement","hand_judgement","hand_quote"', lines.first
    rows = lines.drop(1)
    assert_equal 100, rows.size
    assert_equal 25, rows.map { |r| r[/\A"([^"]+)"/, 1] }.uniq.size
    assert rows.all? { |r| r.count('"').even? }, "a field with an unescaped quote would break the CSV"
  end

  test "every positive hand judgement carries a quote found verbatim in that CV; negatives may be empty" do
    DemoGlassbox::PEOPLE.each do |person|
      cv = DemoGlassbox.cv_text(person)
      person[:hand].each do |code, (judgement, quote)|
        verified = Screening::QuoteCheck.verified?(judgement:, quote:, extracted: cv, redacted: cv)
        assert verified, "#{person[:key]} #{code}: judgement #{judgement.inspect} with quote #{quote.inspect} is not verified against the CV"
      end
    end
  end

  test "control: the planted fake quote is NOT in its CV, so the evidence check must reject it" do
    DemoGlassbox::PLANTED.each do |key, (code, fake)|
      person = DemoGlassbox::PEOPLE.find { |p| p[:key] == key }
      cv = DemoGlassbox.cv_text(person)
      judgement, real_quote = person[:hand].fetch(code)
      refute Screening::QuoteCheck.verified?(judgement:, quote: fake, extracted: cv, redacted: cv), "the planted quote was found in the CV: the step 7 scene would show nothing"
      assert Screening::QuoteCheck.verified?(judgement:, quote: real_quote, extracted: cv, redacted: cv), "the real hand quote must still verify (control)"
    end
  end

  test "every vacancy's should-have weights sum to 100 and every requirement code is scored once per applicant" do
    DemoGlassbox::JOBS.each do |key, spec|
      weights = spec[:requirements].select { |(_c, tier, *)| tier == "sebaiknya" }.sum { |(*, w)| w.to_i }
      assert_equal 100, weights, "#{spec[:title]}: should-have weights sum to #{weights}"
      codes = spec[:requirements].map(&:first)
      DemoGlassbox::PEOPLE.select { |p| p[:job] == key }.each do |person|
        assert_equal codes.sort, person[:hand].keys.sort, "#{person[:key]} scores #{person[:hand].keys.inspect}, expected #{codes.inspect}"
      end
    end
  end

  test "every seeded salary band floor is at or above the Kota Tangerang 2026 minimum wage" do
    DemoGlassbox::JOBS.each_value do |spec|
      assert_operator spec[:salary].first, :>=, DemoGlassbox::UMK_2026, "#{spec[:title]} floor below UMK"
    end
    # Rp 5,399,405.69 rounded UP to whole rupiah; rounding down would sit below the legal minimum.
    assert_equal 5_399_406, DemoGlassbox::UMK_2026
  end

  test "the CVs carry no gender pronoun and no religion word in their evidence sections (the redactor does not strip them there)" do
    leak = /\b(?:he|she|his|her|him|hers|himself|herself|christian|catholic|protestant|muslim|islamic|buddhist|hindu|church|mosque)\b/i
    DemoGlassbox::PEOPLE.each do |person|
      evidence = Screening::EvidenceSections.keep(DemoGlassbox.cv_text(person))
      refute_nil evidence, "#{person[:key]}: no evidence section found"
      refute_match leak, evidence, "#{person[:key]}: evidence text carries a word the evidence-section pass would not redact"
    end
  end
end
