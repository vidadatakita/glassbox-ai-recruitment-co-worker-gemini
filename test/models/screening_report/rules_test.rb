require "test_helper"

# Feature 08 plain-Ruby rules (D62 h1, h3, h5; SPEC §1). Boundaries on both sides of every edge.
class ScreeningReport::RulesTest < ActiveSupport::TestCase
  Decision = Struct.new(:outcome, :reason_code)
  Part = Struct.new(:attendance)
  Attempt = Struct.new(:due_at, :answered_at, :grace_seconds)

  test "band: equal bands of 20, one decimal, 100 is 5 (h1)" do
    { "0" => 1, "19.9" => 1, "20" => 2, "39.9" => 2, "40" => 3, "59.9" => 3, "60" => 4, "79.9" => 4,
      "80" => 5, "100" => 5 }.each { |score, band| assert_equal band, ScreeningReport::Band.of(BigDecimal(score)), score }
    assert_nil ScreeningReport::Band.of(nil)
    assert_raises(ArgumentError) { ScreeningReport::Band.of(100.1) }
    assert_raises(ArgumentError) { ScreeningReport::Band.of(-0.1) }
  end

  test "budget: below, within (inclusive ends, partial overlap), above, not given, no band (h5)" do
    fit = ->(emin, emax, bmin = 6_000_000, bmax = 8_000_000) { ScreeningReport::Budget.fit(expected_min: emin, expected_max: emax, band_min: bmin, band_max: bmax) }
    assert_equal :below, fit.(4_000_000, 5_999_999)
    assert_equal :within, fit.(4_000_000, 6_000_000), "touching the band's lower end is inside"
    assert_equal :within, fit.(7_000_000, 7_500_000)
    assert_equal :within, fit.(8_000_000, 9_000_000), "touching the upper end is inside"
    assert_equal :above, fit.(8_000_001, 9_000_000)
    assert_equal :not_given, fit.(nil, nil)
    assert_equal :no_band, fit.(7_000_000, 8_000_000, nil, nil)
  end

  test "over-qualified needs a last-role Golongan two or more above the job, never anything else (h3)" do
    allowed = ->(last, job) { ScreeningReport::Labels.over_qualified_allowed?(last_role_golongan: last, job_golongan: job) }
    assert allowed.(5, 3)
    refute allowed.(4, 3), "one Golongan above is not over-qualified"
    refute allowed.(3, 3)
    refute allowed.(nil, 3), "no Golongan, no label"
    assert_equal %i[last_role_golongan job_golongan], ScreeningReport::Labels.method(:over_qualified_allowed?).parameters.map(&:last),
                 "the rule has no years-of-experience or age input"
  end

  test "gate cell: both pass, waiting, which part failed, S1 alone without the gate" do
    pass = Decision.new("pass", "x")
    out = Decision.new("eliminate", "below_threshold")
    review = Decision.new("review", "x")
    assert_equal :passed, ScreeningReport::GateCell.of(pass, pass, gated: true)
    assert_equal :open, ScreeningReport::GateCell.of(pass, nil, gated: true)
    assert_equal :open, ScreeningReport::GateCell.of(pass, review, gated: true)
    assert_equal :failed_test, ScreeningReport::GateCell.of(pass, out, gated: true)
    assert_equal :failed_cv, ScreeningReport::GateCell.of(out, Decision.new("eliminate", "gate_eliminated"), gated: true)
    assert_equal :failed_cv, ScreeningReport::GateCell.of(out, nil, gated: false)
    assert_equal :passed, ScreeningReport::GateCell.of(pass, nil, gated: false), "package 2: S1 decides alone"
    assert_equal :open, ScreeningReport::GateCell.of(nil, nil, gated: false)
  end

  test "test cell: every state, timer edge with the recorded grace" do
    now = Time.zone.parse("2026-10-10 10:00")
    cell = ->(**kw) { ScreeningReport::TestCell.of(**{ participation: Part.new("pending"), decision: nil, score: nil, attempt: nil, submitted_at: now - 1.hour, now: }.merge(kw)) }
    assert_equal :none, cell.(participation: nil).state
    assert_equal :gate_eliminated, cell.(decision: Decision.new("eliminate", "gate_eliminated")).state
    scored = cell.(score: BigDecimal("82"))
    assert_equal [:scored, BigDecimal("82")], [scored.state, scored.score]
    assert_equal :expired, cell.(participation: Part.new("no_show")).state
    assert_equal :not_started, cell.(submitted_at: now - 48.hours).state, "exactly 48 h: still open"
    assert_equal :expired, cell.(submitted_at: now - 48.hours - 1.second).state
    assert_equal :in_progress, cell.(attempt: Attempt.new(now - 120.seconds, nil, 120)).state, "inside the grace"
    assert_equal :expired, cell.(attempt: Attempt.new(now - 121.seconds, nil, 120)).state
    assert_equal :awaiting_review, cell.(attempt: Attempt.new(now - 1.hour, now - 2.hours, 120)).state
    assert_equal "not started", cell.().label
    assert_equal "expired", cell.(participation: Part.new("no_show")).label
  end

  test "expected salary: optional, both ends, typed the Indonesian way" do
    parse = ScreeningReport::ExpectedSalary.method(:parse)
    assert_equal [nil, nil, nil], parse.("", " ").to_h.values_at(:min, :max, :error)
    assert_equal [7_000_000, 8_500_000], parse.("Rp 7.000.000", "8500000").to_h.values_at(:min, :max)
    assert_equal [7_000_000, 7_000_000], parse.("7.000.000", "7.000.000").to_h.values_at(:min, :max), "min = max allowed"
    assert_match(/minimum salary cannot be more than the maximum/, parse.("8.000.000", "7.999.999").error)
    assert_match(/leave both empty/, parse.("7000000", "").error)
    assert_match(/leave both empty/, parse.("tujuh juta", "8000000").error)
    assert_match(/more than Rp0/, parse.("0", "5").error)
    assert_match(/too large/, parse.("1", "10000000000").error)
  end
end
