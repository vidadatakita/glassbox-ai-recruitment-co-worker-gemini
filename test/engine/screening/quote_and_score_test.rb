require "test_helper"
require_relative "screening_engine_support"

# Blueprint §4.1 steps 4-6: the model judges, Ruby computes the score; a quote not found in the
# extracted CV text is `unverified` and goes to the reviewer; a failed wajib eliminates; nilai
# tambah is bonus only and never eliminates.
class EngineScreeningQuoteAndScoreTest < ActiveSupport::TestCase
  include ScreeningEngineSupport

  EXTRACTED = "PENGALAMAN\n2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang\nMengelola stok 1.200 SKU dengan aplikasi WMS.\nNama : Rina Pratiwi\nMemiliki SIM C".freeze

  def verified?(judgement, quote, extracted: EXTRACTED)
    redacted = Screening::Redactor.call(extracted, names: ["Rina Pratiwi"]).text
    Screening::QuoteCheck.verified?(judgement:, quote:, extracted:, redacted:)
  end

  test "quote check: verbatim passes; fabricated, changed digit, changed case and paraphrase fail" do
    assert verified?("met", "Admin Gudang di PT Logistik Makmur"), "control: a verbatim quote verifies"
    assert verified?("3", "Mengelola stok 1.200 SKU"), "control"
    refute verified?("met", "Supervisor Gudang di PT Sentosa Abadi"), "fabricated"
    refute verified?("3", "Mengelola stok 1.300 SKU"), "one digit changed"
    refute verified?("3", "mengelola stok 1.200 sku"), "case changed: a paraphrase is not a quote"
    refute verified?("2", "Mengelola stok 1200 SKU"), "punctuation dropped"
    refute verified?("met", "Admin Gudang di PT Logistik Makmur, Jakarta"), "a true prefix with an invented tail"
  end

  test "quote check: whitespace-only differences verify; line breaks inside the CV are spaces" do
    assert verified?("met", "Admin  Gudang\tdi PT\nLogistik Makmur")
    assert verified?("met", "Cikarang Mengelola stok"), "the quote spans a line break of the extracted text"
    refute verified?("met", "AdminGudang di PT Logistik Makmur"), "removing a space is not whitespace normalisation"
  end

  test "quote check: an empty quote fails a positive judgement and is allowed for a negative one" do
    refute verified?("met", "")
    refute verified?("1", "   \n ")
    assert verified?("not_met", "")
    assert verified?("0", "")
    refute verified?("not_met", "Sertifikat K3 Umum"), "a negative judgement carrying an invented quote is still a defect"
  end

  # The model only sees redacted text, so the builder checks a quote containing the marker against
  # the redacted text. A quote that is NOTHING BUT the marker then verifies, although it quotes no
  # CV text at all (§4.1 step 6: "a quote that is not found in the extracted CV text").
  test "quote check: a quote that is only the redaction marker is not evidence" do
    marker = Screening::Redactor::MARK
    results = { marker => verified?("met", marker), "#{marker}." => verified?("3", "#{marker}."),
                " #{marker} " => verified?("met", " #{marker} ") }
    assert_equal({ marker => false, "#{marker}." => false, " #{marker} " => false }, results,
                 "a positive judgement backed only by '[REDACTED]' must be unverified")
  end

  test "end to end: a positive wajib backed only by '[REDACTED]' is routed to the reviewer, never auto-passed" do
    job = screening_job
    fake = FakeGemini.new
    calibrated_open_job!(job, fake)
    wajib = keys_of(job, "wajib").first
    participation, = screen_text!(job, FIXTURE_CV, replies: [gemini_message(criteria_with(job, { wajib => { judgement: "met", quote: "[REDACTED]" } }))],
                                                   name: "Calon Penanda")
    result = participation.screening_results.sole
    assert_equal 1, result.unverified_count, "the marker-only quote must count as unverified"
    item = Screening::ReviewQueue.new(job).items.find { |i| i.participation.id == participation.id }
    assert_equal "unverified", item&.reason
  end

  # A quote that genuinely spans a marker is the builder's documented extension: it verifies
  # against the text the model saw. Control for the test above.
  test "quote check: a verbatim quote spanning a redaction marker verifies against the redacted text" do
    assert verified?("met", "aplikasi WMS. [REDACTED]\nMemiliki SIM C")
    refute verified?("met", "aplikasi WMS. [REDACTED] Memiliki SIM B"), "still verbatim"
  end

  def rubric(weights)
    reqs = []
    reqs << Screening::Sample::Req.new(1, "wajib", "Pendidikan minimal D3", "Ijazah", nil, 1)
    weights.each_with_index { |w, i| reqs << Screening::Sample::Req.new(10 + i, "sebaiknya", "Syarat #{i}", "Bukti", w, 2 + i) }
    reqs << Screening::Sample::Req.new(99, "nilai_tambah", "SIM C", "SIM C", nil, 50)
    Screening::Rubric.new(reqs)
  end

  def judge(rubric, wajib: "met", ratings: [], bonus: "0")
    sebaiknya = rubric.criteria.select { |c| c.tier == "sebaiknya" }
    j = rubric.criteria.to_h do |c|
      value = case c.tier
              when "wajib" then wajib
              when "sebaiknya" then ratings.fetch(sebaiknya.index(c))
              else bonus
              end
      [c.key, { "judgement" => value, "verified" => true }]
    end
    Screening::Score.compute(rubric, j)
  end

  # Hand-computed oracle: score = sum(weight x rating / 3), one decimal, half up.
  test "score: hand-computed values, identical judgements give the identical score" do
    r = rubric([60, 40])
    assert_equal BigDecimal("100.0"), judge(r, ratings: %w[3 3]).score
    assert_equal BigDecimal("0.0"), judge(r, ratings: %w[0 0]).score
    assert_equal BigDecimal("60.0"), judge(r, ratings: %w[3 0]).score       # 60
    assert_equal BigDecimal("53.3"), judge(r, ratings: %w[2 1]).score       # 40 + 13.33
    assert_equal BigDecimal("66.7"), judge(r, ratings: %w[2 2]).score       # 66.67 -> 66.7
    assert_equal BigDecimal("26.7"), judge(r, ratings: %w[0 2]).score       # 26.67
    r3 = rubric([34, 33, 33])
    assert_equal BigDecimal("33.3"), judge(r3, ratings: %w[1 1 1]).score    # 100/3
    scores = Array.new(5) { judge(r3, ratings: %w[2 3 1]).score }
    assert_equal 1, scores.uniq.size
    assert_equal BigDecimal("66.7"), scores.first                            # 68/3 + 33 + 11 = 66.67
  end

  test "score: the threshold is inclusive (60.0 at threshold 60 passes; 59.x eliminates)" do
    r = rubric([60, 40])
    at = judge(r, ratings: %w[3 0])
    below = judge(rubric([59, 41]), ratings: %w[3 0])
    assert_equal BigDecimal("59.0"), below.score
    assert_equal :pass, Screening::Score.outcome(wajib_met: at.wajib_met, score: at.score, threshold: 60).outcome
    assert_equal :eliminate, Screening::Score.outcome(wajib_met: below.wajib_met, score: below.score, threshold: 60).outcome
  end

  test "score: a wajib not met eliminates by rule whatever the score; nilai tambah never moves score or outcome" do
    r = rubric([60, 40])
    failed = judge(r, wajib: "not_met", ratings: %w[3 3], bonus: "3")
    assert_equal BigDecimal("100.0"), failed.score, "the score is still computed and shown"
    out = Screening::Score.outcome(wajib_met: failed.wajib_met, score: failed.score, threshold: 0)
    assert_equal [:eliminate, :rule, "wajib_not_met"], [out.outcome, out.basis, out.reason_code]
    no_bonus = judge(r, ratings: %w[3 0], bonus: "0")
    full_bonus = judge(r, ratings: %w[3 0], bonus: "3")
    assert_equal no_bonus.score, full_bonus.score, "nilai tambah must not move the score"
    assert_equal [0, 3, 3], [no_bonus.bonus_points, full_bonus.bonus_points, full_bonus.bonus_possible]
    low = judge(r, ratings: %w[3 3], bonus: "0")
    assert_equal :pass, Screening::Score.outcome(wajib_met: low.wajib_met, score: low.score, threshold: 60).outcome,
                 "a nilai tambah rated 0 never eliminates"
  end

  test "end to end: the stored ScoreEntry is the Ruby score, not anything the model says" do
    job = screening_job
    sebaiknya = keys_of(job, "sebaiknya") # weights 60 then 40 (rubric order)
    weights = Screening::Rubric.for(job).criteria.select { |c| c.tier == "sebaiknya" }.map(&:weight)
    assert_equal [60, 40], weights, "control on the fixture"
    criteria = criteria_with(job, { sebaiknya[0] => { judgement: "2", quote: "Admin Gudang di PT Logistik Makmur" },
                                    sebaiknya[1] => { judgement: "1", quote: "Microsoft Excel tingkat lanjut" } })
    text = JSON.generate(criteria: criteria, score: 99, total: 99)
    participation, = screen_text!(job, FIXTURE_CV, replies: [gemini_message(nil, text:)])
    # An extra top-level key is outside the schema; whether it is refused or ignored, no 99 is stored.
    entry = participation.score_entries.first
    refute_equal BigDecimal("99"), entry&.value
    participation2, = screen_text!(job, FIXTURE_CV, replies: [gemini_message(criteria)], name: "Calon Dua")
    assert_equal BigDecimal("53.3"), participation2.score_entries.sole.value
    assert_equal BigDecimal("53.3"), participation2.screening_results.sole.score
  end
end
