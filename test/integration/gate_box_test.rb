require "test_helper"

# D60 slice 1 on screen: the vacancy home shows the gate "CV screening and technical test" with both
# stages' counts side by side and the gate result per applicant. Client roles see numbers, not
# names (rule 14, D62 h7).
class GateBoxTest < ActionDispatch::IntegrationTest
  include GateFactory

  setup do
    @job, @s1, @s2 = gated_job
    @job.update!(client_company: company)
    Gates::Open.call(stage: @s1)
    @s1.reload
    @s2.reload
    @out1, @out2 = applicant("Bayu Ardiansyah")
    @in1, @in2 = applicant("Citra Maharani")
    @wait1, @wait2 = applicant("Dodi Firmansyah")
    scored_decision!(@out1, 40, "eliminate")
    scored_decision!(@in1, 85, "pass")
    @in2.update!(attendance: "attended")
    scored_decision!(@in2, 72, "pass")
    scored_decision!(@wait1, 80, "pass")
  end

  test "the gate box shows both stages side by side, the gate totals and each applicant's result" do
    sign_in_as staff_user("consultant")
    get staff_job_path(@job)
    assert_response :success
    box = css_select("#gerbang-seleksi").first
    assert box, "gate box missing"
    assert_includes box.text, "CV screening and technical test"
    stages = css_select("#gerbang-seleksi .gate-stage")
    assert_equal ["CV screening", "Technical test"], stages.map { |s| s.at_css("h4").text.split(" ·").first.strip }
    # S1: 3 in, 2 passed, 1 out, 0 waiting. S2: 3 in, 1 passed, 0 out, 2 waiting.
    assert_equal %w[3 2 1 0], stages[0].css("dd").map { |d| d.text.strip }
    assert_equal %w[3 1 0 2], stages[1].css("dd").map { |d| d.text.strip }
    summary = css_select("#gerbang-seleksi .gate-summary__num").map { |n| n.text.strip }
    assert_equal %w[1 1 1], summary, "passed / waiting / not passed"
    rows = css_select("#gerbang-seleksi tbody tr").map { |tr| tr.css("td").first(4).map { |td| td.text.strip } }
    assert_equal ["Dodi Firmansyah", "Passed", "Not decided yet", "Waiting"], rows.first, "waiting first"
    assert_includes rows, ["Citra Maharani", "Passed", "Passed", "Passed"]
    assert_includes rows, ["Bayu Ardiansyah", "Not passed", "Not decided yet", "Not passed"]
    assert_house_rules
  end

  test "after the gate closes, the S1 elimination shows as not scored on the test" do
    @wait2.update!(attendance: "attended")
    scored_decision!(@wait2, 30, "eliminate")
    Gates::Close.call(stage: @s1)
    sign_in_as staff_user("consultant")
    get staff_job_path(@job)
    assert_includes css_select("#gerbang-seleksi h3").first.text, "Closed"
    row = css_select("#gerbang-seleksi tbody tr").find { |tr| tr.text.include?("Bayu Ardiansyah") }
    assert_includes row.text, "Not assessed: eliminated at CV screening"
  end

  test "HR PIC and owner see numbered candidates, never names; DataKita staff see names" do
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      table = css_select("#gerbang-seleksi table").first.to_html
      %w[Bayu Citra Dodi].each { |name| refute_includes table, name, "#{role} sees a name" }
      assert_includes table, "Candidate 01"
    end
    sign_in_as staff_user("reviewer")
    get staff_job_path(@job)
    assert_includes css_select("#gerbang-seleksi table").first.to_html, "Citra Maharani", "control: staff see names"
  end

  test "a job without a gate shows no gate box (control)" do
    job = portal_job
    sign_in_as staff_user("consultant")
    get staff_job_path(job)
    assert_response :success
    assert_empty css_select("#gerbang-seleksi")
  end

  private

  def applicant(name)
    candidate = Candidate.create!(name:, email: "#{name.split.first.downcase}@uji.example", phone: "081234567890")
    application = JobApplication.create!(job: @job, candidate:, consent_at: Time.current, consent_template: publish_consent,
                                         consent_retention_days: 30)
    [Participation.create!(job_application: application, stage: @s1, attendance: "attended"),
     Participation.create!(job_application: application, stage: @s2, attendance: "pending")]
  end

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]")
    refute_match(/fa-eye\b/, response.body)
  end
end
