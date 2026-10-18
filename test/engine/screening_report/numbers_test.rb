require "test_helper"
require_relative "engine08_support"

# Engine 08: the numbers on the report. Band boundaries (D62 h1), the gate cell over all sixteen
# decision pairs (D60), the S2 state boundaries (48 h start window, timer + grace), FIT: Budget at
# band edges (h5), expected-salary parsing, sort order with ties (h9), and the tie-outs (rule 20):
# the report's "Lolos" count = an independent count over Decision rows = the gate board's = the
# xlsx's; the xlsx rows = the screen rows, same order and values.
class Engine08NumbersTest < ActionDispatch::IntegrationTest
  include Engine08Support

  setup do
    set_retention
    publish_consent
  end

  test "band: every boundary of D62 h1, nil, and out-of-range refused" do
    { 0 => 1, 19.9 => 1, 20 => 2, 20.0 => 2, 39.9 => 2, 40 => 3, 59.9 => 3, 60 => 4, 79.9 => 4, 80 => 5, 99.9 => 5, 100 => 5 }.each do |score, band|
      assert_equal band, ScreeningReport::Band.of(score), "score #{score}"
      assert_equal band, ScreeningReport::Band.of(BigDecimal(score.to_s)), "BigDecimal #{score}"
    end
    assert_nil ScreeningReport::Band.of(nil)
    [100.1, -0.1].each { |s| assert_raises(ArgumentError) { ScreeningReport::Band.of(s) } }
  end

  test "gate cell: all sixteen S1 x S2 decision pairs on a gated job and S1 alone on package 2" do
    outcomes = [nil, "pass", "eliminate", "review"]
    d = ->(o) { o && Decision.new(outcome: o, reason_code: "x") }
    outcomes.product(outcomes).each do |o1, o2|
      expected = if o1 == "eliminate" then :failed_cv
                 elsif o2 == "eliminate" then :failed_test
                 elsif [o1, o2] == %w[pass pass] then :passed
                 else :open
                 end
      assert_equal expected, ScreeningReport::GateCell.of(d.(o1), d.(o2), gated: true), "gated #{o1.inspect}/#{o2.inspect}"
      solo = { "pass" => :passed, "eliminate" => :failed_cv }.fetch(o1, :open)
      assert_equal solo, ScreeningReport::GateCell.of(d.(o1), d.(o2), gated: false), "package 2 #{o1.inspect}"
    end
    assert_equal %w[Passed Waiting Not\ passed\ (CV) Not\ passed\ (test)], %i[passed open failed_cv failed_test].map { ScreeningReport::GateCell.word(it) }
  end

  test "S2 cell: 48 h start window and timer + grace at the exact second" do
    now = Time.zone.parse("2026-10-10 12:00:00")
    p2 = Struct.new(:attendance).new("pending")
    of = ->(attempt: nil, submitted_at: now - 1.hour, decision: nil, score: nil) do
      ScreeningReport::TestCell.of(participation: p2, decision:, score:, attempt:, submitted_at:, now:).state
    end
    assert_equal :not_started, of.(submitted_at: now - 48.hours)
    assert_equal :expired, of.(submitted_at: now - 48.hours - 1.second)
    attempt = Struct.new(:due_at, :answered_at, :grace_seconds)
    assert_equal :in_progress, of.(attempt: attempt.new(now - 120.seconds, nil, 120))
    assert_equal :expired, of.(attempt: attempt.new(now - 121.seconds, nil, 120))
    assert_equal :awaiting_review, of.(attempt: attempt.new(now - 1.day, now - 2.days, 120)), "an answer before expiry is awaiting review"
    assert_equal :scored, of.(score: 0), "a score of 0 is a score, not 'not started'"
    assert_equal :gate_eliminated, of.(score: 77, decision: Decision.new(outcome: "eliminate", reason_code: "gate_eliminated"))
    assert_equal :expired, ScreeningReport::TestCell.of(participation: Struct.new(:attendance).new("no_show"), decision: nil, score: nil,
                                                        attempt: nil, submitted_at: now, now:).state
    assert_equal :none, ScreeningReport::TestCell.of(participation: nil, decision: nil, score: 50, attempt: nil, submitted_at: now, now:).state
  end

  test "FIT: Budget at every band edge (both ends inclusive) and the not-given / no-band states" do
    fit = ->(lo, hi, bmin: 7_500_000, bmax: 9_000_000) { ScreeningReport::Budget.fit(expected_min: lo, expected_max: hi, band_min: bmin, band_max: bmax) }
    assert_equal :within, fit.(7_000_000, 7_500_000)
    assert_equal :below, fit.(7_000_000, 7_499_999)
    assert_equal :within, fit.(9_000_000, 9_500_000)
    assert_equal :above, fit.(9_000_001, 9_500_000)
    assert_equal :within, fit.(6_000_000, 12_000_000), "a range that covers the band overlaps"
    assert_equal :not_given, fit.(nil, nil)
    assert_equal :no_band, fit.(7_000_000, 8_000_000, bmin: nil, bmax: nil)
    assert_equal :no_band, fit.(7_000_000, 8_000_000, bmax: nil), "half a band is no band"
  end

  test "expected salary parsing: integer rupiah only, both or neither, min <= max, storage guard" do
    ok = ->(a, b) { r = ScreeningReport::ExpectedSalary.parse(a, b); assert_nil r.error, "#{a.inspect}-#{b.inspect}: #{r.error}"; [r.min, r.max] }
    bad = ->(a, b) { refute_nil ScreeningReport::ExpectedSalary.parse(a, b).error, "#{a.inspect}-#{b.inspect} accepted" }
    assert_equal [7_500_000, 9_000_000], ok.("7.500.000", "Rp 9.000.000")
    assert_equal [7_500_000, 7_500_000], ok.("Rp.7500000", "7 500 000")
    assert_equal [nil, nil], ok.("", "  ")
    ["7.500.000,50", "7,5 jt", "-1", "0", "abc", "１２３"].each { |v| bad.(v, "9.000.000") }
    bad.("7.500.000,50", "900.000.000")
    bad.("7.500.000", "")
    bad.("", "9.000.000")
    bad.("9.000.001", "9.000.000")
    bad.("1", "10.000.000.000")
    assert_equal [9_999_999_999, 9_999_999_999], ok.("9.999.999.999", "9999999999")
    assert_kind_of Integer, ok.("7.500.000", "9.000.000").first
  end

  test "database: a half or inverted expected-salary range is refused; a full range is accepted (control)" do
    job, s1, s2 = e8_job
    app, = e8_applicant(job, s1, s2, name: "Gaji DB Uji")
    sql = ->(lo, hi) { ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute("UPDATE job_applications SET expected_salary_min = #{lo}, expected_salary_max = #{hi} WHERE id = #{app.id}") } }
    [["7000000", "NULL"], ["NULL", "8000000"], ["9000000", "8000000"], ["0", "8000000"]].each do |lo, hi|
      assert_raises(ActiveRecord::StatementInvalid, "#{lo}-#{hi} accepted") { sql.(lo, hi) }
    end
    sql.("7000000", "7000000")
    assert_equal [7_000_000, 7_000_000], app.reload.then { [it.expected_salary_min, it.expected_salary_max] }
  end

  # Rule 20 tie-out on a gated job with every gate result: four independent views of "who passed"
  # must agree, and a control flip of one Decision must move all of them by one.
  test "tie-out: Passed on the report = Decision rows (S1 pass AND S2 pass) = gate board = xlsx; control flip moves all" do
    job, s1, s2 = e8_job
    plan = { "Ani" => %w[pass pass], "Budi" => %w[pass eliminate], "Cici" => ["eliminate", nil], "Dodi" => ["pass", nil],
             "Euis" => %w[review pass], "Fajar" => %w[pass pass], "Gita" => [nil, nil] }
    parts = plan.to_h do |name, (o1, o2)|
      _app, p1, p2 = e8_applicant(job, s1, s2, name: "#{name} Uji")
      e8_result(p1, score: 50 + name.ord % 40)
      e8_decide(p1, o1) if o1
      e8_decide(p2, o2) if o2
      [name, [p1, p2]]
    end
    views = lambda do
      ids1 = s1.participations.pluck(:id)
      cur = Decision.current.where(participation_id: ids1 + s2.participations.pluck(:id)).to_h { |d| [d.participation_id, d.outcome] }
      independent = s1.participations.count { |p1| p2 = s2.participations.find_by(job_application_id: p1.job_application_id); cur[p1.id] == "pass" && cur[p2.id] == "pass" }
      board = e8_board(job, staff_user("consultant"))
      gate_board = GateBoard.new(job.reload).rows.count { |r| r.result == :passed } rescue :gate_board_unavailable
      sign_in_as staff_user("consultant")
      get staff_job_screening_report_path(job)
      metric = Nokogiri::HTML(response.body).css(".loan-index-metric").find { |m| m.text.include?("Passed CV screening") }.at("strong").text.to_i
      get staff_job_screening_report_export_path(job)
      x = e8_xlsx(response.body)
      gate_col = x[:header].index("CV screening result")
      xlsx_count = x[:rows][4..].count { |r| r[gate_col] == "Passed" }
      sign_out
      { independent:, board: board.counts.fetch(:passed, 0), metric:, xlsx: xlsx_count, gate_board: }
    end
    before = views.call
    assert_equal 2, before[:independent], "fixture: Ani and Fajar"
    before.each { |view, n| assert_equal before[:independent], n, "view #{view} disagrees: #{before}" }
    e8_decide(parts["Dodi"][1], "pass")
    after = views.call
    after.each { |view, n| assert_equal 3, n, "control flip: view #{view} did not move: #{after}" }
  end

  test "xlsx rows = screen rows: same order, same name, band, S2, gate, salary, label; band formula cached = Band.of" do
    job, s1, s2 = e8_job
    specs = [["Ani", 81, "pass", "pass", 77, [8_000_000, 9_000_000]], ["Budi", 19.9, "eliminate", nil, nil, nil],
             ["Cici", 60, nil, nil, 0, [5_000_000, 6_000_000]], ["Dodi", 59.9, "pass", "eliminate", 40, [9_500_000, 12_000_000]]]
    specs.each do |name, score, o1, o2, s2v, sal|
      _a, p1, p2 = e8_applicant(job, s1, s2, name: "#{name} Uji", salary: sal)
      e8_result(p1, score:)
      e8_decide(p1, o1) if o1
      e8_decide(p2, o2) if o2
      e8_s2_score(p2, s2v) if s2v
    end
    e8_judge_calibration!(job)
    # The superadmin sees names before the gate closes (three roles, 17 Oct 2026); a blind role's
    # rows read "Candidate NN", so the name comparison below would not be about names.
    sign_in_as staff_user("admin")
    get staff_job_screening_report_path(job)
    screen = Nokogiri::HTML(response.body).css("table.report-table tbody tr").map do |tr|
      cell = ->(label) { tr.at("td[data-label='#{label}']") }
      { name: tr.at("td.report-table__person a").text.strip, band: cell.("AI score (S1)").at("strong")&.text&.delete_suffix("/5"),
        s2: cell.("Technical test score").text.strip, gate: cell.("CV screening result").text.strip,
        salary: cell.("Expected salary").children.first.text.strip, fit: cell.("Expected salary").at("small").text.strip,
        label: cell.("Label").css("span, small").map { it.text.strip }.join(" ") }
    end
    get staff_job_screening_report_export_path(job)
    x = e8_xlsx(response.body)
    h = x[:header]
    data = x[:rows][4, specs.size]
    assert_equal screen.size, data.size
    screen.zip(data).each do |s, r|
      assert_equal s[:name], r[h.index("Name")]
      formula, cached = r[h.index("AI score (S1) 1–5")].split("|")
      n = x[:rows].index(r) + 1
      assert_equal %(=IF(D#{n}="","",MIN(5,INT(D#{n}/20)+1))), formula, "band formula: own row, D62 h1 bands"
      assert_equal s[:band], cached, "cached band = screen band for #{s[:name]}"
      assert_equal ScreeningReport::Band.of(BigDecimal(r[h.index("AI score (S1) 0–100")])).to_s, cached
      assert_equal s[:s2], ScreeningReport::Text.score(r[h.index("Technical test score (S2)")].to_f).then { |v| r[h.index("Technical test score (S2)")] =~ /\A[\d.]+\z/ ? v : r[h.index("Technical test score (S2)")] }
      assert_equal s[:gate], r[h.index("CV screening result")]
      assert_equal s[:salary], r[h.index("Expected salary")]
      assert_equal s[:fit], r[h.index("FIT: Budget")]
      assert_equal s[:label].sub(" AI advice", " (AI advice)").sub(" confirmed by reviewer", " (confirmed by reviewer)"), r[h.index("Label")]
    end
    assert_equal ["Ani Uji", "Cici Uji", "Dodi Uji", "Budi Uji"], screen.map { it[:name] }, "Passed, Waiting, then Not passed by AI score (59.9 before 19.9)"
    footer = x[:rows].last.compact.join
    assert_includes footer, "CONFIDENTIAL"
    # Owner ruling 2026-10-10/11 (re-confirmed by GlassBox Team 2026-10-12 20:28, "2 ok"): users never see
    # technical details, so the footer names no model or prompt (they stay in the records).
    refute_match(/#{Regexp.escape(MODEL)}|#{Regexp.escape(PROMPT)}/, footer)
    formulas = x[:rows].each_with_index.flat_map { |r, i| r.each_with_index.filter_map { |v, j| [i, j] if v.to_s.match?(/\A=.*\|/) } }
    assert_equal (4...4 + specs.size).map { [it, h.index("AI score (S1) 1–5")] }, formulas, "the band column is the ONLY formula, one per data row"
  end

  test "sort ties (h9): same gate and AI score -> S2 desc -> earlier application; 0.0 AI before no AI; nil S2 last" do
    job, s1, s2 = e8_job
    base = 3.days.ago
    rows = [["Late", 70, nil, base + 2.hours], ["Early", 70, nil, base + 1.hour], ["WithS2", 70, 80, base + 3.hours],
            ["Zero", 0.0, nil, base], ["NoAI", nil, nil, base - 1.hour], ["LowS2", 70, 10, base + 4.hours]]
    rows.each do |name, ai, s2v, at|
      _a, p1, p2 = e8_applicant(job, s1, s2, name: "#{name} Uji", applied: at)
      e8_result(p1, score: ai) if ai
      e8_s2_score(p2, s2v) if s2v
    end
    e8_judge_calibration!(job)
    names = e8_board(job, staff_user("consultant")).rows.map { it.candidate.name.delete_suffix(" Uji") }
    assert_equal %w[WithS2 LowS2 Early Late Zero NoAI], names
  end
end
