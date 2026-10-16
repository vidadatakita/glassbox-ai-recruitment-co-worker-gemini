require "test_helper"
require_relative "engine08_support"

# Engine 08: formula injection through every candidate- or AI-controlled text column of the xlsx
# (D62 h8: = + - @ TAB CR prefixed), read back from the bytes the controller sent. The only formula
# in the sheet may be the band column; every payload must arrive as TEXT with exactly one leading
# apostrophe (a double escape would show '' to the reader).
class Engine08XlsxEscapeTest < ActionDispatch::IntegrationTest
  include Engine08Support

  PAYLOADS = ["=1+1", "+1+1", "-1+1", "@SUM(A1:A2)", "\t=1+1", "\r=1+1", "=cmd|' /C calc'!A0",
              "=HYPERLINK(\"http://contoh.example/x\",\"klik\")", "-2+3+cmd|' /C calc'!A0", "@cmd|'/c notepad'!A1"].freeze

  setup do
    set_retention
    publish_consent
    @job, @s1, @s2 = e8_job
  end

  def export_as(role)
    sign_in_as staff_user(role)
    get staff_job_screening_report_export_path(@job)
    assert_response :success
    x = e8_xlsx(response.body)
    sign_out
    x
  end

  def plant(payload, i)
    _a, p1, _p2 = e8_applicant(@job, @s1, @s2, name: "Uji #{i}", email: "uji#{i}@uji.example")
    p1.job_application.candidate.update_columns(name: payload, email: payload, phone: payload)
    e8_result(p1, score: 50 + i, last_position: e8_fact(payload, quote: "q"))
    ScreeningReport::RecordUserRecommendation.call(application: p1.job_application, user: staff_user("hr_pic"), user_name: payload, pick: "lanjut")
  end

  test "every D62 h8 prefix and DDE payload in Name, Last position, Email and WhatsApp number is text with exactly one leading apostrophe" do
    PAYLOADS.each_with_index { |p, i| plant(p, i) }
    x = export_as("consultant")
    h = x[:header]
    cols = ["Name", "Last position", "Email", "WhatsApp number"].map { |c| h.index(c) || flunk("column #{c} missing") }
    data = x[:rows][4, PAYLOADS.size]
    seen = data.flat_map { |r| cols.map { r[it] } }
    assert seen.all? { it.to_s.start_with?("'") && !it.to_s.start_with?("''") }, "a cell without exactly one apostrophe: #{seen.reject { it.to_s.start_with?("'") }.inspect}"
    PAYLOADS.each do |p|
      want = "'#{p.tr("\r", "\n")}"
      assert_operator seen.count { it == want }, :>=, 3, "payload #{p.inspect} not found escaped in Name, Email and WhatsApp"
    end
    formulas = x[:rows].flatten.compact.select { it.to_s.match?(/\A=.*\|/) }
    assert formulas.all? { it.start_with?("=IF(D") }, "a formula other than the band: #{formulas.reject { it.start_with?('=IF(D') }.inspect}"
    rec = data.map { it[h.index("Hiring manager's pick")] }
    assert rec.all? { it.start_with?("#{UserRecommendation::PICKS.fetch("lanjut").first} · ") }, "Hiring manager's pick starts with the pick, so the typed name is never at the cell start"
  end

  test "a job title starting with = is escaped in the masthead and never becomes a formula" do
    @job.update_columns(title: "=HYPERLINK(\"http://contoh.example\")")
    _a, p1, _p2 = e8_applicant(@job, @s1, @s2, name: "Uji Judul")
    e8_result(p1, score: 70)
    x = export_as("consultant")
    assert x[:rows][0].first.start_with?("Screening report · ="), "masthead starts with fixed text"
    refute x[:all].include?("<f>HYPERLINK"), "the job title became a formula"
  end

  # Not in D62 h8's list. Excel does not evaluate a cell that starts with a space or with the
  # full-width "＝" (U+FF1D), so these are probed for the property that matters (no formula in the
  # file), not for the prefix list.
  test "probe outside the list: leading space, full-width equals, newline-first never become formulas" do
    [" =1+1", "  @SUM(A1)", "＝1+1", "＋1", "\n=1+1"].each_with_index { |p, i| plant(p, i) }
    x = export_as("consultant")
    assert_equal 0, x[:all].scan(/<f>(?!IF\(D)/).size, "a formula other than the band in the file"
  end

  test "blind HR PIC export: no Email / WhatsApp columns, no name, CONFIDENTIAL footer without model or prompt, -anonim- filename" do
    _a, p1, _p2 = e8_applicant(@job, @s1, @s2, name: "Rahasia Nama Uji", email: "rahasia.e8@uji.example", phone: "0813-5555-0000")
    e8_result(p1, score: 70)
    x = export_as("hr_pic")
    refute_includes x[:header], "Email"
    refute_includes x[:header], "WhatsApp number"
    refute x[:all].include?("Rahasia Nama"), "name in a blind export"
    refute x[:all].include?("rahasia.e8"), "email in a blind export"
    refute x[:all].include?("5555-0000"), "phone in a blind export"
    assert_includes x[:rows][4], "Candidate 01"
    footer = x[:rows].last.compact.join
    # Owner ruling 2026-10-10/11, re-confirmed 2026-10-12 20:28: no model or prompt shown to users.
    assert_match(/\ACONFIDENTIAL · for the recruitment of .* · generated .* WIB\z/, footer)
    refute_match(/#{Regexp.escape(MODEL)}|#{Regexp.escape(PROMPT)}/, footer)
  end
end
