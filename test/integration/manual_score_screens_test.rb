require "test_helper"

# "Nilai Tes psikologi" on the applicant page (2026-10-13): the HR PIC sees the form on the S4 row,
# saves a score through it, and the row then shows the score instead of the form. The hr_manager
# gets no form, and the controller refuses its post.
class ManualScoreScreensTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    Rails.cache.clear
    @job = briefed_job(golongan: 4, package: 4)
    @job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id, consultant_id: staff_user("consultant").id)
    open_portal(@job)
    @application, = applicant!(@job)
    @s4 = enter_stage_by_choice!(@application, @job.stages.find_by!(code: "S4"))
  end

  def form_doc
    doc = Nokogiri::HTML(response.body)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form" }
    assert_empty doc.css("button[disabled], [data-disable-with]"), "disabled submit"
    doc.at_css("form[action='#{staff_participation_manual_score_path(@s4)}']")
  end

  test "the HR PIC enters the Tes psikologi score through the form; the row then shows it" do
    sign_in_as staff_user("hr_pic")
    get staff_application_path(@application)
    form = form_doc
    assert form, "the HR PIC sees the score form on the Tes psikologi row"
    assert_includes form.text, "Psychological test score"
    %w[attendance value tested_on note].each { |name| assert form.at_css("[name=#{name}]"), name }

    post staff_participation_manual_score_path(@s4), params: { attendance: "attended", value: "82,5", tested_on: "", note: "" }
    assert_redirected_to staff_application_path(@application, anchor: "stage-#{@s4.id}")
    follow_redirect!
    assert_includes response.body, "Psychological test score saved."
    assert_includes response.body, "Psychological test: <strong>82.5</strong>"
    assert_nil form_doc, "the form is gone once the score is recorded"
  end

  test "a wrong value comes back as a message with the typed value kept; nothing is written" do
    sign_in_as staff_user("hr_pic")
    post staff_participation_manual_score_path(@s4), params: { attendance: "attended", value: "150" }
    follow_redirect!
    assert_includes response.body, "Enter a score from 0 to 100."
    assert_equal "150", form_doc.at_css("[name=value]")["value"]
    assert_empty @s4.score_entries
  end

  # GlassBox Team asked for an Interview 2 form too (2026-10-13): it is the same scorecard as Interview 1
  # (score_source "scorecard"), so it already appears once the candidate is in S5. Pinned here.
  test "Interview 2 shows the interview scorecard to the HR PIC and saves a score" do
    s5 = enter_stage_by_choice!(@application, @job.stages.find_by!(code: "S5"))
    if @job.competencies.where(stage_code: "S5").none?
      layer = @job.competencies.pick(:layer) || "core"
      2.times { |i| @job.competencies.create!(position: 90 + i, stage_code: "S5", layer:, name: "Kompetensi uji #{i + 1}") }
    end
    competencies = @job.competencies.where(stage_code: "S5").to_a
    sign_in_as staff_user("hr_pic")
    get staff_application_path(@application)
    form = Nokogiri::HTML(response.body).at_css("form[action='#{staff_participation_interview_path(s5)}']")
    assert form, "the Interview 2 scorecard is on the page"
    assert_includes form.text, "Interview scoring"

    post staff_participation_interview_path(s5), params: { attendance: "attended", ratings: competencies.to_h { |c| [ c.id, 4 ] } }
    assert_equal BigDecimal("75"), s5.reload.current_score, "rating 4 of 5 on every competency"
  end

  # Three roles (17 Oct 2026): the consultant is an hr_admin now and may score like the HR PIC;
  # the hr_manager (reviewer, owner) sees no form and is refused.
  test "the hr_manager sees no form and its post is refused" do
    %w[reviewer owner].each do |role|
      sign_in_as staff_user(role)
      get staff_application_path(@application)
      assert_nil form_doc, role if response.successful?
      post staff_participation_manual_score_path(@s4), params: { attendance: "attended", value: "90" }
      assert_empty @s4.score_entries, role
    end
  end
end
