require "test_helper"
require_relative "engine08_support"

# Engine 08: house rules on every report page as every role that can open it (no nested form, no
# disabled submit and a submit guard that never disables, fa-plus for "view", the GlassBox wording
# standard), the Lamar salary field, and the candidate side (portal principle 4: the candidate
# never sees the report, a score or a label).
class Engine08HouseRulesTest < ActionDispatch::IntegrationTest
  include Engine08Support

  FORBIDDEN = /\b(Terapkan|diterapkan|Tautan|berkas|unggah|diunggah|Tatap muka)\b/i

  setup do
    set_retention
    publish_consent
    @job, @s1, @s2 = e8_job
    @ja, @p1, @p2 = e8_applicant(@job, @s1, @s2, name: "Puspita Uji")
    e8_result(@p1, score: 66)
  end

  def check_page(where)
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/i).size, doc.css("form").size, "#{where}: a form inside a form"
    doc.css("form").each { |f| assert_empty f.css("form"), "#{where}: nested form" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with], [data-turbo-submits-with]"), "#{where}: disabled submit"
    assert_empty doc.css("i.fa-eye"), "#{where}: fa-eye used"
    text = doc.at("body").text.gsub(/\s+/, " ")
    refute_match FORBIDDEN, text, "#{where}: wording standard"
  end

  test "every report page as every role: no nested form, no disabled submit, no fa-eye, wording standard" do
    %w[consultant reviewer hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_report_path(@job)
      check_page("#{role} list")
      assert_select "td.hris-table-actions a[title^='View report'] i.fa.fa-plus", 1
      get staff_job_screening_report_candidate_path(@job, @ja.id)
      check_page("#{role} detail")
      sign_out
    end
  end

  test "the submit guard never disables (JS source), and every report form is guarded" do
    js = File.read(Rails.root.join("app/javascript/submit_guard.js"))
    code = js.lines.reject { it.strip.start_with?("//") }.join
    refute_match(/disabled|disable-with|submits-with|\.submit\(\)/, code)
    sign_in_as staff_user("reviewer")
    get staff_job_screening_report_candidate_path(@job, @ja.id)
    forms = css_select("main form, .screening-report form")
    assert forms.any?, "control: the reviewer sees the label form"
    forms.each { |f| assert_equal "true", f["data-submit-guard"], "a report form without the guard" }
  end

  test "view sources: wording standard in every feature-08 view and the Lamar salary partial" do
    files = Dir[Rails.root.join("app/views/staff/screening_reports/*.erb")] + [Rails.root.join("app/views/lamar/_expected_salary.html.erb").to_s]
    assert_operator files.size, :>=, 15
    files.each do |f|
      visible = File.read(f).gsub(/<%#.*?%>/m, "")
      refute_match FORBIDDEN, visible, File.basename(f)
      refute_match(/fa-eye"/, visible, File.basename(f))
    end
  end

  test "the candidate's status page shows no report, score, band, label or narrative" do
    job = portal_job
    open_portal(job) if respond_to?(:open_portal)
    application, token = submit!(job, name: "Calon Tidak Melihat", email: "calon.tm@uji.example")
    p1 = application.participations.find_by!(stage: job.stages.find_by!(code: "S1"))
    p1.update!(attendance: "attended")
    e8_result(p1, score: 87.5, label: "direkomendasikan",
                  narratives: e8_narratives(strengths: [e8_claim("Kekuatan rahasia uji", quote: "q")]))
    get candidate_status_path(token)
    assert_response :success
    body = response.body
    ["87,5", "87.5", "5/5", "Direkomendasikan", "Recommended", "Pertimbangkan", "Kekuatan rahasia uji", "Analisa", "Draf AI", "AI draft",
     "Laporan Analisis", "Screening report", "Criteria scoring", "laporan-analisis", "Supervisor Akuntansi, PT Uji Niaga"].each do |s|
      refute body.include?(s), "the candidate sees '#{s}'"
    end
    assert_includes body, job.title, "control: this is the candidate's own page"
  end
end
