require "test_helper"
require_relative "ai_release_engine_support"

# Feature 09 test engine, run 1: "Pemeriksaan sebelum AI" through real requests. The screen must
# show exactly the bytes that are sent; client users and consultants never reach it or its text;
# house rules (no nested form, no disabled submit, fa-plus for view) and the wording standard.
class EngineAiReleaseScreensTest < ActionDispatch::IntegrationTest
  include AiReleaseEngineSupport

  BANNED = /\b(tautan|berkas|unggah|terapkan|tatap\s+muka)\b/i
  MARKER_LINE = "Mengelola stok 1.200 SKU dengan aplikasi WMS".freeze

  setup do
    Rails.cache.clear
    @job = screening_job
  end

  def assert_house_rules(path)
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{path}"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with], [data-turbo-submits-with]"), path
    assert_empty doc.css(".fa-eye"), path
    main = doc.at_css("section.content") || doc.at_css("main") || doc
    refute_match BANNED, main.text, "wording standard on #{path}"
  end

  test "the screen shows the exact payload bytes and the API receives the same bytes (whitespace and unicode)" do
    cv = "PENGALAMAN KERJA\n2017 - 2024\tAdmin  Gudang di PT Logistik Makmur   \nMengelola stok café (NFD: café), ekspedisi 東京 dan الرياض 📦\nnon breaking space\nKEAHLIAN\nExcel"
    participation, fake, release = hold!(@job, cv)
    sign_in_as releaser
    get staff_ai_release_path(release)
    assert_response :success
    pre = Nokogiri::HTML(response.body).at_css("pre.release-payload")
    assert_equal release.payload_text, pre.text, "the screen is not the payload byte for byte"
    assert_equal release.payload_sha256, pre["data-payload-sha256"]
    with_ai(fake) do
      fake.push(gemini_message(criteria_for(@job)))
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256, commit: "Kirim ke AI" }
      drain_jobs!(release: false)
    end
    sent = sent_contents(fake)
    assert_equal 1, sent.size
    assert_equal release.payload_text.b, sent.first.b, "sent bytes differ from the released bytes"
    assert_equal AiRelease.digest(sent.first), release.payload_sha256
    assert_equal "done", participation.reload.screening_state
  end

  test "release via the screen needs the tick and the digest of the version on screen" do
    _, fake, release = hold!(@job)
    sign_in_as releaser
    with_ai(fake) do
      post staff_ai_release_send_path(release), params: { payload_sha256: release.payload_sha256, commit: "Kirim ke AI" }
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: "0" * 64, commit: "Kirim ke AI" }
    end
    assert_equal 0, AiReleaseAction.count
  end

  # Three roles (17 Oct 2026): both HR Admin people are refused everything; the HR Manager and the
  # superadmin reach the list and the text (control, read only; their actions are tested elsewhere).
  test "the HR Admin never reaches the release list, the text, or an action; the HR Manager and the superadmin read it" do
    participation, fake, release = hold!(@job)
    %w[owner admin].each do |role|
      sign_in_as staff_user(role)
      get staff_job_ai_releases_path(@job)
      assert_response :success, role
      get staff_ai_release_path(release)
      assert_response :success, role
      assert_includes response.body, MARKER_LINE, role
    end
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_job_ai_releases_path(@job)
      assert_redirected_to staff_jobs_path, role
      get staff_ai_release_path(release)
      assert_redirected_to staff_jobs_path, role
      with_ai(fake) do
        post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256 }
        post staff_ai_release_cut_path(release), params: { lines: [release.cv_line_start + 1] }
        post staff_ai_release_decline_path(release), params: { note: "uji" }
      end
      [staff_job_path(@job), staff_work_queue_path].each do |path|
        get path
        next unless response.successful?

        refute_includes response.body, MARKER_LINE, "#{role} sees the release text on #{path}"
      end
    end
    assert_equal [0, 1], [AiReleaseAction.count, AiRelease.where(participation:).count]
  end

  test "the job's consultant who is a reviewer may read but every action is refused at the controller" do
    _, fake, release = hold!(@job)
    reviewer = staff_user("reviewer", email: "rangkap@uji.example")
    @job.update!(consultant: reviewer)
    sign_in_as reviewer
    get staff_ai_release_path(release)
    assert_response :success
    with_ai(fake) do
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256 }
      assert_equal "The reviewer cannot be the consultant of this vacancy.", flash[:alert]
      post staff_ai_release_cut_path(release), params: { lines: [release.cv_line_start + 1] }
      post staff_ai_release_decline_path(release), params: { note: "uji" }
    end
    assert_equal [0, 1], [AiReleaseAction.count, AiRelease.count]
  end

  test "release pages, job page and Antrean Kerja: house rules and wording; findings summary shows no value" do
    cv = EVIDENCE_CV.sub("Mengelola stok", "Bekasi, 12-03-1995\nMengelola stok")
    _, _, release = hold!(@job, cv)
    hold!(@job, EVIDENCE_CV, name: "Calon Bersih")
    sign_in_as releaser
    [staff_job_ai_releases_path(@job), staff_ai_release_path(release), staff_job_path(@job), staff_work_queue_path].each do |path|
      get path
      assert_response :success, path
      assert_house_rules(path)
    end
    get staff_ai_release_path(release)
    doc = Nokogiri::HTML(response.body)
    outside = doc.css("body").first.dup
    outside.css("pre.release-payload").each(&:remove)
    refute_includes outside.text, "12-03-1995", "a residual value appears outside the text block"
    assert doc.at_css("pre.release-payload mark"), "control: the finding is marked inside the block"
  end
end
