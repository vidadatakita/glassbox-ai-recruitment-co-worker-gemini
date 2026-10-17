require "test_helper"
require_relative "screening_engine_support"

# Feature 06 staff screens, attacked through real requests: blind calibration judging (§4.1 step
# 7), the reviewer refusals at the controller (§1.2), the sample seed never shown (rule 19), the
# house rules (no nested form, no disabled submit, fa-plus for view), the GlassBox wording
# standard (never Tautan / berkas / unggah / Terapkan / Tatap muka), and rule 14 for client users.
class EngineScreeningStaffScreensTest < ActionDispatch::IntegrationTest
  include ScreeningEngineSupport

  BANNED = /\b(tautan|berkas|unggah|terapkan|tatap\s+muka)\b/i

  setup do
    Rails.cache.clear
    @job = screening_job
    @fake = FakeGemini.new
  end

  # The feature's own parts of a page: the screening box on the job page / Antrean Kerja, or the
  # whole content section of the feature's own pages.
  def feature_fragments
    doc = Nokogiri::HTML(response.body)
    doc.css("#screening, section.content")
  end

  def assert_house_rules_on_feature
    assert_equal response.body.scan(/<form\b/).size, Nokogiri::HTML(response.body).css("form").size, "a form inside a form on #{request.path}"
    fragments = feature_fragments
    assert_operator fragments.size, :>, 0, "control: the feature's section is on #{request.path}"
    fragments.each do |f|
      assert_empty f.css("form form")
      assert_empty f.css("button[disabled], input[type=submit][disabled], [data-disable-with], [data-turbo-submits-with]"), request.path
      assert_empty f.css("i.fa-eye, .fa-eye"), "view icon must be fa-plus on #{request.path}"
      f.css("a").select { |a| a.text =~ /Lihat/ }.each do |a|
        assert a.at_css("i.fa-plus"), "a 'Lihat' link without fa-plus on #{request.path}: #{a.to_html[0, 120]}"
      end
      text = f.text
      refute_match BANNED, text, "wording standard on #{request.path}"
      refute_match(/diterapkan/i, text)
    end
  end

  # AI score 53.3 (sebaiknya 2 and 1 on weights 60/40), an elimination at threshold 60: a value the
  # consultant would recognise on any screen.
  def distinctive_criteria
    keys = keys_of(@job, "sebaiknya")
    criteria_with(@job, { keys[0] => { judgement: "2", quote: "Admin Gudang di PT Logistik Makmur" },
                          keys[1] => { judgement: "1", quote: "Microsoft Excel tingkat lanjut" } })
  end

  test "blind calibration: before judging, the consultant sees the AI score on no screen; after judging, it shows" do
    participation, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(distinctive_criteria)])
    assert_equal BigDecimal("53.3"), participation.screening_results.sole.score, "control: the AI result exists"
    sign_in_as @job.consultant
    [staff_job_screening_calibration_path(@job), staff_job_path(@job), staff_application_path(participation.job_application),
     staff_work_queue_path].each do |path|
      get path
      assert_response :success, path
      refute_match(/53[,.]3/, response.body, "the AI score is visible to the consultant before judging on #{path}")
    end
    get staff_job_screening_calibration_path(@job)
    assert_includes response.body, "Hidden until the HR Admin has judged"
    post staff_participation_calibration_path(participation), params: { outcome: "pass", commit: "Save judgement" }
    get staff_job_screening_calibration_path(@job)
    assert_match(/53,3/, response.body, "control: after judging, the AI answer is shown")
  end

  # D13 blinds the role that judges calibration. Three roles (17 Oct 2026): the hr_admin judges
  # calibration, so every hr_admin (the consultant and the HR PIC alike) is blinded; the hr_manager
  # does not judge and reads the score of an unjudged calibration CV on the applicant page.
  # D13 blinds only the judge: the job's consultant (an HR Admin). Another HR Admin and the HR Manager do
  # not judge calibration, so they see the score (2026-10-13 complaint; three roles, 17 Oct 2026).
  test "blind calibration: only the judging consultant is blinded; another HR Admin and the HR Manager see the score" do
    participation, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(distinctive_criteria)])
    sign_in_as @job.consultant
    get staff_application_path(participation.job_application)
    refute_match(/53[,.]3/, response.body, "control: hidden from the judging consultant")
    [staff_user("hr_pic"), staff_user("owner")].each do |user|
      sign_in_as user
      get staff_application_path(participation.job_application)
      assert_response :success
      assert_match(/53[,.]3/, response.body, "#{user.email_address} (#{user.role}) does not judge and should see the AI score")
      refute_includes response.body, "Hasil AI disembunyikan"
    end
  end

  # Three roles (17 Oct 2026): the review belongs to the hr_manager; the hr_admin is refused; the
  # superadmin passes every role check (allowed side pinned below with a GET only, so no review is written).
  test "Review Screening: hr_admin roles get no screen and cannot post a review; the job's consultant neither" do
    calibrated_open_job!(@job, @fake)
    p, = screen_text!(@job, FIXTURE_CV, replies: [gemini_message(criteria_for(@job, wajib: "not_met"))], name: "Calon Layar")
    result = p.screening_results.sole
    %w[consultant hr_pic].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_review_path(@job)
      assert_redirected_to staff_jobs_path, role
      post staff_screening_result_review_path(result), params: { verdict: "confirm", commit: "Simpan review" }
      assert_redirected_to staff_jobs_path, role
    end
    %w[owner admin].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_review_path(@job)
      assert_response :success, "control: #{role} (#{staff_user(role).role}) opens the review screen"
    end
    reviewer = staff_user("reviewer")
    @job.update!(consultant: reviewer)
    sign_in_as reviewer
    get staff_job_screening_review_path(@job)
    assert_includes response.body, "cannot also review its screening"
    assert_select "form[action='#{staff_screening_result_review_path(result)}']", 0
    post staff_screening_result_review_path(result), params: { verdict: "confirm", commit: "Save review" }
    assert_equal "The reviewer cannot be the consultant of this vacancy.", flash[:alert]
    assert_equal 0, ScreeningReview.count
    assert_nil p.reload.current_decision
  end

  test "the reviewer's screen: house rules, wording, fa-plus; the sample seed appears on no page" do
    calibrated_open_job!(@job, @fake)
    screen_text!(@job, FIXTURE_CV, replies: [gemini_message(criteria_for(@job, wajib: "not_met"))], name: "Calon Tinjau")
    seed = @job.reload.screening_sample_seed
    assert seed.present?, "control: the seed exists"
    sign_in_as staff_user("reviewer")
    get staff_job_screening_review_path(@job)
    assert_response :success
    assert_select "form[action^='/staff/screening_results/']", minimum: 1
    assert_house_rules_on_feature
    refute_includes response.body, seed
    [staff_job_path(@job), staff_job_screening_calibration_path(@job), staff_work_queue_path].each do |path|
      get path
      assert_house_rules_on_feature
      refute_includes response.body, seed, path
    end
    sign_in_as @job.consultant
    [staff_job_path(@job), staff_job_screening_calibration_path(@job), staff_work_queue_path].each do |path|
      get path
      assert_house_rules_on_feature
      refute_includes response.body, seed, path
    end
  end

  test "failure and unreadable screens follow the house rules and the wording standard" do
    screen_text!(@job, FIXTURE_CV, replies: [refusal_message(category: "cyber")], name: "Calon Ditolak")
    unreadable = with_ai(@fake) { apply_with_cv!(@job, name: "Calon Scan", pdf: pdf_without_text).tap { drain_jobs! } }
    assert_equal "cv_unreadable", unreadable.reload.screening_state
    sign_in_as @job.consultant
    get staff_job_path(@job)
    assert_includes response.body, "Screening failed"
    assert_includes response.body, "CV unreadable"
    assert_house_rules_on_feature
    get staff_participation_cv_text_path(unreadable)
    assert_house_rules_on_feature
    post staff_participation_cv_text_path(unreadable), params: { cv_text: "terlalu pendek", commit: "Save CV text" }
    assert_response :unprocessable_entity
    assert_house_rules_on_feature
    Screening::Config.stub(:api_key, nil) do
      get staff_job_path(@job)
      assert_house_rules_on_feature
      get staff_work_queue_path
      assert_house_rules_on_feature
    end
  end

  # Rule 14 / P14: client users see S1 candidates as numbers. The job page box does it
  # (ScreeningHelper#screening_person); the Antrean Kerja screening section prints the name.
  test "client users (hr_pic, owner) see no candidate name in the screening sections" do
    screen_text!(@job, FIXTURE_CV, replies: [refusal_message(category: "cyber")], name: "Sekar Ayuningtyas")
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      box = Nokogiri::HTML(response.body).at_css("#screening")
      assert box, "control: the screening box renders for #{role}"
      refute_includes box.text, "Sekar", "job page box, #{role}"
      get staff_work_queue_path
      next unless response.successful?

      section = Nokogiri::HTML(response.body).at_css("#screening")
      next unless section

      refute_includes section.text, "Sekar", "Antrean Kerja screening section shows the candidate's name to #{role}"
    end
  end
end
