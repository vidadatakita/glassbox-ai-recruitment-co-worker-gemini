require "test_helper"

# Role matrix for the staff screens (slice plan rule 16; BP §1.2) and the house form rules on
# every staff page.
class StaffAccessTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @job = portal_job
  end

  def assert_house_form_rules
    doc = Nokogiri::HTML(response.body)
    doc.css("form").each { |form| assert_empty form.css("form"), "nested form on #{request.path}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
  end

  test "logged-out requests to staff screens go to Masuk" do
    get staff_jobs_path
    assert_redirected_to new_session_path
  end

  # A browser that opened a candidate status page (and so carries that session cookie) still
  # reaches nothing under /staff. The old version only added the token as a query parameter that
  # no staff action reads, so it could not fail (test engine, hunt item 7).
  test "a browser that opened a candidate status page reaches nothing under /staff" do
    open_portal(@job)
    application, token = submit!(@job)
    get candidate_status_path(token)
    assert_response :success
    [staff_jobs_path, staff_application_path(application), cv_staff_application_path(application), staff_settings_path].each do |path|
      get path
      assert_redirected_to new_session_path, path
    end
  end

  test "hr_pic opens the portal; the event records the role" do
    set_retention
    publish_consent
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_open_path(@job), params: { closes_at: "2030-10-24T17:00", quota: "120", commit: "Buka Portal" }
    assert_redirected_to staff_job_path(@job)
    event = @job.application_window_events.last
    assert_equal ["open", "hr_admin", 120], [event.action, event.actor_role, event.quota]
    assert_equal Time.utc(2030, 10, 24, 10, 0), event.closes_at, "17.00 WIB typed, 10.00 UTC stored"
  end

  test "the portal refuses to open without the retention period, and the screen says why" do
    publish_consent
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_open_path(@job), params: { commit: "Buka Portal" }
    follow_redirect!
    assert_includes response.body, "The data retention period has not been set in Settings."
    assert_equal 0, @job.application_window_events.count
  end

  test "a reviewer cannot open the portal" do
    set_retention
    publish_consent
    sign_in_as staff_user("reviewer")
    post staff_job_portal_open_path(@job)
    assert_equal 0, @job.application_window_events.count
  end

  test "only admin reaches System settings, and a change writes an audit row" do
    sign_in_as staff_user("hr_pic")
    get staff_settings_path
    assert_redirected_to staff_jobs_path
    sign_out

    sign_in_as staff_user("admin")
    get staff_settings_path
    assert_response :success
    assert_includes response.body, "Not set"
    assert_includes response.body, "check with your legal counsel"
    assert_house_form_rules
    patch staff_settings_path, params: { key: "retention_days", value: "60", commit: "Simpan" }
    change = SettingChange.last
    assert_equal ["retention_days", nil, "60"], [change.key, change.old_value, change.new_value]
  end

  # Team lead's live click, 16 Oct 2026: the admin opened a vacancy, clicked an applicant, and was
  # sent back with "You do not have access". The link must not render for a role that cannot open the
  # page. Three roles (17 Oct 2026): every role may open an applicant now (the superadmin passes every
  # role check), so the link renders for each and each rendered link must open, never bounce.
  test "the job page renders applicant links only for roles that may open an applicant, and each link opens" do
    open_portal(@job)
    submit!(@job)
    %w[admin hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      assert_response :success
      links = css_select("a[href^='/staff/applications/']")
      assert links.any?, "#{role} gets the applicant link"
      get links.first["href"]
      assert_response :success, "#{role}: the rendered applicant link opens"
      sign_out
    end
  end

  test "a setting key that is not a screen setting is refused (ONP-3)" do
    sign_in_as staff_user("admin")
    patch staff_settings_path, params: { key: "TENANCY", value: "multi" }
    follow_redirect!
    assert_includes response.body, "Unknown setting."
    assert_equal 0, SettingChange.count
  end

  # Three roles (17 Oct 2026): the offer upload belongs to the hr_admin, so the hr_manager is refused.
  # Answering an objection is open to hr_admin and hr_manager alike (and the superadmin), so no
  # signed-in role is refused it any more; its allowed side is pinned in the portal engine test.
  test "an hr_manager cannot upload an offer" do
    open_portal(@job)
    application, = submit!(@job)
    %w[owner reviewer].each do |role|
      sign_in_as staff_user(role)
      post staff_application_offers_path(application), params: { offer: { day_one_notes: "x" } }
      assert_redirected_to staff_jobs_path, role
      sign_out
    end
    assert_equal 0, OfferDocument.count
  end

  test "the person who decided the S1 elimination cannot answer the objection against it (D40)" do
    open_portal(@job)
    application, = submit!(@job)
    objection = s1_objection_for(application, decided_by: staff_user("reviewer"))
    sign_in_as staff_user("reviewer")
    post staff_objection_answer_path(objection), params: { outcome: "not_upheld", answer: "tetap" }
    assert_nil objection.reload.answered_at
    follow_redirect!
    assert_includes response.body, "must be answered by someone else"
    sign_out
    sign_in_as staff_user("consultant")
    post staff_objection_answer_path(objection), params: { outcome: "not_upheld", answer: "tetap" }
    assert_not_nil objection.reload.answered_at
  end

  test "only the consultant marks a failed email handled, and who did it is recorded (F11, F12)" do
    open_portal(@job)
    application, = submit!(@job)
    failure = MailDelivery.create!(job_application: application, kind: "status_link", status: "failed", error_class: "SocketError")
    sign_in_as staff_user("reviewer")
    post handle_mail_failure_staff_work_queue_path(failure)
    assert_nil failure.reload.handled_at
    sign_out
    consultant = staff_user("consultant")
    sign_in_as consultant
    post handle_mail_failure_staff_work_queue_path(failure)
    assert_equal consultant.id, failure.reload.handled_by_id
  end

  # An S1 elimination on a closed stage with an open objection against it.
  def s1_objection_for(application, decided_by: nil)
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    participation = application.participations.find_by!(stage: s1)
    participation.update!(attendance: "attended")
    add_score(participation, 40)
    Decision.create!(participation:, outcome: "eliminate", basis: "threshold", reason_code: "below_threshold",
                     decided_by_id: decided_by&.id, decided_at: Time.current)
    Stages::Close.call(stage: s1)
    Portal::CandidateActions.new(application).object!(participation.id, "Saya keberatan")
  end

  test "staff pages render and keep the house form rules" do
    open_portal(@job)
    application, = submit!(@job)
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      [staff_jobs_path, staff_job_path(@job), staff_application_path(application), staff_work_queue_path].each do |path|
        get path
        assert_response :success, "#{role} #{path}"
        assert_house_form_rules
      end
      sign_out
    end
  end

  test "while S1 is closed the portal box explains instead of offering a reopen form that would fail" do
    open_portal(@job)
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    Stages::Close.call(stage: s1)
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@job)
    assert_includes response.body, "CV screening is closed, so the Applicant portal cannot be opened again"
    assert_select "form[action=?]", staff_job_portal_reopen_path(@job), 0
    assert_select ".portal-state", text: "Closed (CV screening complete)"
  end

  # antislop audit 001 #3: an empty queue section says what would appear there and from where, so
  # an empty queue reads differently from a broken one.
  test "every empty work-queue section says what would appear there" do
    sign_in_as staff_user("consultant")
    get staff_work_queue_path
    refute_match(/>None\.</, response.body, "a bare 'None.' empty state")
    assert_includes response.body, "Applicants who press"
    assert_includes response.body, "Objections applicants raise"
  end

  # antislop audit 001 #4(b): the unfinished reset flow is not linked from Sign in.
  test "Sign in does not link the unconfigured password reset" do
    get new_session_path
    assert_select "a[href=?]", new_password_path, 0
    assert_includes response.body, "Contact the admin to reset it."
  end

  test "the view/detail action uses fa-plus, never fa-eye (house rule)" do
    sign_in_as staff_user("hr_pic")
    get staff_jobs_path
    assert_select "a[title='View vacancy details'] i.fa-plus"
    refute_includes response.body, "fa-eye"
  end
end
