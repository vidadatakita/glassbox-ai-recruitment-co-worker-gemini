require "test_helper"

# Feature 09 (D51 B), "Pemeriksaan sebelum AI": who may open it, that the text block IS the payload,
# that findings never leave the text block, and the house form rules.
class AiReleaseScreensTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @reviewer = staff_user("reviewer")
    leaky = FIXTURE_CV.sub("Mengelola stok", "Lhr. Bdg 01-02-1990\nSebagai ibu dua anak saya disiplin\nMengelola stok")
    with_ai(@fake) do
      @participation = apply_with_cv!(@job, cv_text: leaky)
      perform_enqueued_jobs
    end
    @release = AiRelease.latest_for(@participation)
  end

  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    doc.css("form").each { |form| assert_empty form.css("form") }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
  end

  test "HR PIC, owner and consultant never open the screen or its text" do
    %w[hr_pic owner consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_job_ai_releases_path(@job)
      assert_redirected_to staff_jobs_path, role
      get staff_ai_release_path(@release)
      assert_redirected_to staff_jobs_path, role
      post staff_ai_release_send_path(@release), params: { confirmed: "1", payload_sha256: @release.payload_sha256 }
      assert_redirected_to staff_jobs_path, role
    end
    assert_nil @release.reload.action
  end

  test "the text block is the payload byte for byte; values found stay inside it" do
    sign_in_as @reviewer
    get staff_ai_release_path(@release)
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    pre = doc.at_css("pre.release-payload")
    assert_equal @release.payload_text, pre.text
    assert_equal @release.payload_sha256, pre["data-payload-sha256"]
    assert pre.at_css("mark.release-mark--blocking[data-category='birth_date']")
    assert pre.at_css("mark.release-mark--hint[data-category='family']")
    pre.remove
    refute_includes doc.to_html, "01-02-1990", "a found value is never echoed outside the text block"
    refute_includes doc.to_html, "ibu dua anak"
    assert_includes response.body, "date of birth"
    assert_house_form_rules
  end

  test "release refused with findings; cut through the screen; then release; then decline is no longer offered" do
    sign_in_as @reviewer
    post staff_ai_release_send_path(@release), params: { confirmed: "1", payload_sha256: @release.payload_sha256 }
    assert_match "Personal data", flash[:alert]
    line = @release.cv_range.find { |i| @release.lines[i].include?("01-02-1990") }
    post staff_ai_release_cut_path(@release), params: { lines: [line.to_s] }
    fresh = AiRelease.latest_for(@participation)
    assert_redirected_to staff_ai_release_path(fresh)
    assert_equal @reviewer, fresh.cut_by
    with_ai(@fake) do
      post staff_ai_release_send_path(fresh), params: { payload_sha256: fresh.payload_sha256 }
      assert_match "Tick the statement", flash[:alert]
      post staff_ai_release_send_path(fresh), params: { confirmed: "1", payload_sha256: fresh.payload_sha256 }
      assert_redirected_to staff_job_ai_releases_path(@job)
    end
    assert_equal "released", fresh.reload.action.action
    get staff_ai_release_path(fresh)
    assert_select "form[action='#{staff_ai_release_decline_path(fresh)}']", 0
    get staff_job_ai_releases_path(@job)
    refute_includes response.body, fresh.payload_sha256.first(12), "no hash on screen (owner, 2026-10-11)"
    assert_includes response.body, @reviewer.name
  end

  test "Not sent from the screen needs a note and moves the CV to a manual decision" do
    sign_in_as @reviewer
    post staff_ai_release_decline_path(@release), params: { note: "" }
    assert_match "Write the reason", flash[:alert]
    post staff_ai_release_decline_path(@release), params: { note: "Data keluarga di banyak baris" }
    assert_redirected_to staff_job_ai_releases_path(@job)
    assert_equal "not_sent", @participation.reload.screening_state
    # The person who decides by hand sees WHO it is, on the job page and in Antrean Kerja.
    sign_in_as @job.consultant
    get staff_job_path(@job)
    assert_includes response.body, "The reviewer decided not to send this CV to the AI"
    assert_select "a[href='#{staff_application_path(@participation.job_application)}'] i.fa-plus"
    assert_house_form_rules
    get staff_work_queue_path
    assert_includes response.body, "The reviewer decided not to send this CV to the AI"
  end

  test "an erased release's page says it was erased and shows no text" do
    Portal::CandidateActions.new(@participation.job_application).withdraw_consent!
    sign_in_as @reviewer
    get staff_ai_release_path(@release)
    assert_response :success
    assert_includes response.body, "Text erased."
    assert_includes response.body, "Consent withdrawn"
    assert_equal "", Nokogiri::HTML(response.body).at_css("pre.release-payload").text
    refute_includes response.body, "Admin Gudang di PT"
    assert_select "form[action='#{staff_ai_release_send_path(@release)}']", 0
  end

  test "without a key the screen says so and offers no Send to Gemini; the job page shows the pilot line" do
    sign_in_as @reviewer
    Screening::Config.stub(:api_key, nil) do
      get staff_job_ai_releases_path(@job)
      assert_includes response.body, ScreeningBoard::OFF_MESSAGE
      assert_includes response.body, "Awaiting review (1)"
      get staff_job_path(@job)
      assert_includes response.body, "Review before AI"
      assert_includes response.body, "Pilot measure: 1 CVs checked"
      get staff_work_queue_path
      assert_includes response.body, "1 CVs awaiting review"
    end
    sign_in_as staff_user("hr_pic")
    get staff_work_queue_path
    refute_includes response.body, "Buka Pemeriksaan sebelum AI"
  end
end
