require "test_helper"
require_relative "engine08_support"

# Engine 08: who sees names and contacts on the report (D62 h7, SPEC §2.1, rule 14), on every
# channel a person receives: list, detail, xlsx (cells, every XML part, filename), page title, link
# text, title attributes, data attributes. Gate-closed control rows make every refute load-bearing.
class Engine08BlindViewTest < ActionDispatch::IntegrationTest
  include Engine08Support

  NAME_A = "Wulandari Uji Delapan".freeze
  NAME_B = "Hendrawan Uji Delapan".freeze

  setup do
    set_retention
    publish_consent
    @job, @s1, @s2 = e8_job
    @app_a, @a1, @a2 = e8_applicant(@job, @s1, @s2, name: NAME_A, email: "wulan.e8@uji.example", phone: "0813-7777-1111", salary: [8_000_000, 9_000_000])
    @app_b, @b1, @b2 = e8_applicant(@job, @s1, @s2, name: NAME_B, email: "hendra.e8@uji.example", phone: "0813-7777-2222")
    @app_a.update_columns(domicile_city: "Kotauji Rahasia")
    e8_result(@a1, score: 81.0)
    e8_result(@b1, score: 40.0, label: "tidak_prioritas")
  end

  SECRETS = [NAME_A, NAME_B, "Wulandari", "Hendrawan", "wulan.e8", "hendra.e8", "7777-1111", "7777-2222", "Kotauji"].freeze

  def close_gate!
    e8_decide(@a1, "pass")
    e8_decide(@a2, "pass")
    e8_decide(@b1, "eliminate")
    Gates::Close.call(stage: @s1)
    @job.stages.reload
  end

  def assert_no_identity(body, where)
    SECRETS.each { |s| refute body.include?(s), "#{where}: '#{s}' leaked" }
  end

  def visit_all(role)
    sign_in_as staff_user(role)
    out = {}
    get staff_job_screening_report_path(@job)
    assert_response :success
    out[:list] = response.body
    get staff_job_screening_report_candidate_path(@job, @app_a.id)
    assert_response :success
    out[:detail] = response.body
    get staff_job_screening_report_export_path(@job)
    assert_response :success
    out[:filename] = response.headers["Content-Disposition"]
    out[:xlsx] = e8_xlsx(response.body)
    sign_out
    out
  end

  # Three roles (17 Oct 2026): both HR Admin people and both HR Manager people are blind until the
  # gate closes; only the superadmin sees identity before it.
  test "the HR Admin and the HR Manager before the gate closes: no name, email or phone on any channel, numbered instead" do
    %w[hr_pic consultant owner reviewer].each do |role|
      seen = visit_all(role)
      assert_no_identity(seen[:list], "#{role} list")
      assert_no_identity(seen[:detail], "#{role} detail")
      assert_no_identity(seen[:xlsx][:all], "#{role} xlsx (every part)")
      assert_no_identity(seen[:filename], "#{role} filename")
      assert_includes seen[:filename], "-anonim-", "#{role}: blind export filename"
      refute_includes seen[:xlsx][:header], "Email", "#{role}: contact column exists in a blind export"
      refute_includes seen[:xlsx][:header], "WhatsApp number"
      refute_includes seen[:xlsx][:header], "City of residence"
      doc = Nokogiri::HTML(seen[:detail])
      assert_match(/\ACandidate report · Candidate \d\d/, doc.at("title").text.strip, "#{role}: page title")
      list = Nokogiri::HTML(seen[:list])
      list.css("[title], [alt], [aria-label]").each do |el|
        %w[title alt aria-label].each { |attr| refute_match(/Wulandari|Hendrawan/, el[attr].to_s, "#{role}: #{attr}") }
      end
      list.xpath("//@*[starts-with(name(), 'data-')]").each { |a| refute_match(/Wulandari|Hendrawan|7777/, a.value, "#{role}: #{a.name}") }
      assert_equal %w[Candidate\ 01 Candidate\ 02].sort, list.css("td.report-table__person a").map { |a| a.text.strip }.sort
    end
  end

  # Control for the test above: the same channels DO carry the identity for the superadmin, so a
  # refute there is not passing on an empty page.
  test "control: the superadmin sees names and contacts on list, detail and xlsx; the export is not -anonim-" do
    seen = visit_all("admin")
    [NAME_A, "wulan.e8@uji.example", "0813-7777-1111"].each do |s|
      assert_includes seen[:list], s
      assert_includes seen[:xlsx][:all], s
    end
    assert_includes seen[:detail], NAME_A
    assert_includes seen[:detail], "wulan.e8@uji.example"
    refute_includes seen[:filename], "anonim"
    assert_includes seen[:xlsx][:header], "Email"
    assert_includes seen[:xlsx][:header], "WhatsApp number"
  end

  test "after the gate closes: the HR Admin names and contacts; the HR Manager names only; the superadmin both" do
    close_gate!
    expect = { "hr_pic" => [true, true], "consultant" => [true, true], "owner" => [true, false], "reviewer" => [true, false],
               "admin" => [true, true] }
    expect.each do |role, (names, contacts)|
      seen = visit_all(role)
      [[seen[:list], "list"], [seen[:detail], "detail"], [seen[:xlsx][:all], "xlsx"]].each do |body, where|
        assert_equal names, body.include?(NAME_A), "#{role} #{where}: name"
        assert_equal contacts, body.include?("wulan.e8@uji.example"), "#{role} #{where}: email"
        assert_equal contacts, body.include?("0813-7777-1111"), "#{role} #{where}: phone"
        assert_equal contacts, body.include?("Kotauji Rahasia"), "#{role} #{where}: city (SPEC §2.1 HR and consultant only)"
      end
      assert_equal contacts, seen[:xlsx][:header].include?("Email"), "#{role}: Email column"
    end
  end

  # Three roles: the HR Manager (old reviewer) is now blind to names too while the gate is open, and
  # never sees contacts; the superadmin on the same pages is the control that the data is there.
  test "the HR Manager sees neither names nor contacts while the gate is open; the superadmin sees both" do
    seen = visit_all("reviewer")
    refute seen[:list].include?(NAME_A), "the HR Manager saw a name before the gate closed"
    refute seen[:list].include?("wulan.e8@uji.example"), "reviewer saw an email on the list"
    refute seen[:detail].include?("0813-7777-1111"), "reviewer saw a phone on the detail"
    control = visit_all("admin")
    assert control[:list].include?(NAME_A), "control: the superadmin sees names"
    assert control[:detail].include?("0813-7777-1111"), "control: the superadmin sees the phone"
  end

  # Three roles: the superadmin passes every role check, so no signed-in role is refused the report
  # any more; the refusal half is the anonymous visitor.
  test "the superadmin reaches every report route; an anonymous visitor is sent to log in" do
    sign_in_as staff_user("admin")
    [staff_job_screening_report_path(@job), staff_job_screening_report_candidate_path(@job, @app_a.id),
     staff_job_screening_report_export_path(@job)].each do |path|
      get path
      assert_response :success, "the superadmin was refused #{path}"
    end
    sign_out
    get staff_job_screening_report_export_path(@job)
    assert_response :redirect
    refute_match(/spreadsheetml/, response.media_type.to_s)
  end

  test "another job's application id under this job is 404 on show and on every POST" do
    other, o1, o2 = e8_job(title: "Lowongan Lain E8")
    app_x, x1, _x2 = e8_applicant(other, o1, o2, name: "Orang Lain Uji")
    e8_result(x1, score: 70)
    sign_in_as staff_user("consultant")
    get staff_job_screening_report_candidate_path(@job, app_x.id)
    assert_response :not_found
    post staff_job_screening_report_narratives_path(@job, app_x.id)
    assert_response :not_found
    sign_out
    sign_in_as staff_user("hr_pic")
    post staff_job_screening_report_user_recommendation_path(@job, app_x.id), params: { user_name: "Pak Uji", pick: "lanjut" }
    assert_response :not_found
    assert_equal 0, UserRecommendation.where(job_application_id: app_x.id).count
    sign_out
    sign_in_as staff_user("reviewer")
    post staff_job_screening_report_label_path(@job, app_x.id), params: { label: "pertimbangkan" }
    assert_response :not_found
    assert_equal 0, ScreeningLabelConfirmation.where(participation_id: x1.id).count
  end

  # D62 h7 says names are hidden; the report prints model-returned text verbatim (Posisi Terakhir,
  # the CV quotes, the narrative claims). Redaction can miss a header line (engine run 5: 8 of 9
  # planted sentences reached the request body), so a model can echo the candidate's name. The
  # board does not compare that text with the candidate's own name before showing it to a client.
  test "FINDING probe: a candidate name echoed by the model inside Posisi Terakhir or a quote is not shown to a blind HR PIC" do
    _app, c1, _c2 = e8_applicant(@job, @s1, @s2, name: "Kartika Gema Uji")
    e8_result(c1, score: 75, last_position: e8_fact("Kartika Gema Uji, Supervisor Akuntansi PT Uji"),
                  narratives: e8_narratives(strengths: [e8_claim("Teliti", quote: "Kartika Gema Uji menyusun jurnal")]))
    seen = visit_all("hr_pic")
    refute seen[:list].include?("Kartika Gema"), "blind list shows the name through Posisi Terakhir"
    refute seen[:xlsx][:all].include?("Kartika Gema"), "blind xlsx shows the name through Posisi Terakhir"
  end

  # SPEC §2.4: "download the uploaded answer file (HR/consultant only)"; feature 07's answer_file
  # admits reviewer and consultant only. Whatever the rule, a link the report SHOWS must work for
  # the person it is shown to. Uses the builder's invented demo seed (answered + scored attempts),
  # rendered as each role on the gate-closed job; the consultant is the control (link present, 200).
  test "FINDING probe: every 'Download answer' link the report shows opens for the person it is shown to (no dead link)" do
    require Rails.root.join("db/seeds/demo_screening_report").to_s
    _open, closed = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
    a = JobApplication.joins(:candidate).find_by!(job: closed, candidates: { name: "Sample Candidate A" })
    shown = {}
    %w[consultant hr_pic owner reviewer].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_report_candidate_path(closed, a.id)
      links = css_select("a").select { it.text.include?("Download answer") }.map { it["href"] }
      shown[role] = links.size
      links.each do |href|
        get href
        assert_response :success, "#{role} is shown 'Download answer' but the download is refused (#{response.location})"
      end
      sign_out
    end
    assert_equal 1, shown["consultant"], "control: the consultant is shown the link"
  end
end
