require "test_helper"
require_relative "portal_engine_support"

# Hunt items 2 and 3 (brief 02): the application window through real requests (WIB boundary,
# quota, closed by date / quota / HR on BOTH steps, nothing written by an automatic close), and
# consent (D35): never stored without consent, a version never edited, a future version never
# used early, purpose never empty, and the words the candidate SAW are the words stored.
class EnginePortalWindowAndConsentTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  setup do
    Rails.cache.clear
    @job = portal_job
  end

  # A browser-shaped step-2 POST. The consent token is taken from the step-2 page when the window
  # is open (D35 contract); pass consent_token: explicitly to reuse one shown earlier, or nil for
  # a client that never loaded the form.
  def lamar_post(job = @job, overrides = {})
    overrides = overrides.dup
    token = overrides.key?(:consent_token) ? overrides.delete(:consent_token) : (ApplicationWindow.new(job).open? ? step2_token(job) : nil)
    lamaran = application_params(job, overrides).except(:knockout)
    lamaran[:consent_token] = token if token
    post lamar_path(job.public_code), params: { knockout: answers_for(job), lamaran:, commit: "Kirim Lamaran" }
  end

  def candidate_count = JobApplication.where.not(candidate_id: nil).count

  # --- window -------------------------------------------------------------------------------

  test "close time typed as 17.00 WIB by HR: a submission at 16:59:59 WIB is stored, at 17:00:00 WIB is refused (410)" do
    set_retention
    publish_consent
    sign_in_as staff_user("hr_pic")
    travel_to Time.utc(2030, 10, 24, 1, 0) do
      post staff_job_portal_open_path(@job), params: { closes_at: "2030-10-24T17:00", commit: "Open portal" }
    end
    sign_out
    assert_equal Time.utc(2030, 10, 24, 10, 0), @job.application_window_events.sole.closes_at

    late_token = nil
    travel_to Time.utc(2030, 10, 24, 9, 59, 59) do
      late_token = step2_token(@job)
      lamar_post(@job, consent_token: late_token)
      assert_response :success
    end
    travel_to Time.utc(2030, 10, 24, 10, 0, 0) do
      post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
      assert_response :gone, "step 1 still open at the close time"
      lamar_post(@job, email: "late@uji.example", consent_token: late_token)
      assert_response :gone, "step 2 accepted at the close time"
    end
    assert_equal 1, candidate_count
  end

  test "quota 2 (sequential): the 2nd is accepted, the 3rd is refused on step 1 and step 2" do
    open_portal(@job, quota: 2)
    lamar_post(@job, email: "a@uji.example")
    lamar_post(@job, email: "b@uji.example")
    assert_equal 2, candidate_count
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    assert_response :gone
    lamar_post(@job, email: "c@uji.example", consent_token: shown_consent_token)
    assert_response :gone
    assert_equal 2, candidate_count
  end

  test "an automatic close (date or quota) writes nothing anywhere; the window is derived" do
    open_portal(@job, closes_at: 2.hours.from_now, quota: 1)
    lamar_post(@job, email: "a@uji.example")
    travel 3.hours do
      before = ActiveRecord::Base.connection.tables.to_h do |t|
        [t, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{t}").to_i]
      end
      get lamar_path(@job.public_code)
      post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
      lamar_post(@job, email: "b@uji.example", consent_token: shown_consent_token)
      get staff_jobs_path
      after = ActiveRecord::Base.connection.tables.to_h do |t|
        [t, ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{t}").to_i]
      end
      assert_equal before, after
      assert_equal :closed_by_date, ApplicationWindow.new(@job).state
    end
  end

  test "F14 fixed: a closed window refuses a POST to step 2 with 410 even when the form data is invalid" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    lamar_post(@job, phone: "12345", consent_token: shown_consent_token)
    assert_response :gone, "a closed portal answered with the application form instead of 'closed'"
    refute_includes response.body, "Send application", "the form is offered again on a closed portal"
    assert_equal 0, candidate_count
  end

  test "reopen without a reason is refused over HTTP and in the database; with a reason it reopens" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_reopen_path(@job), params: { reason: "  ", commit: "Reopen" }
    assert_equal "close", @job.application_window_events.order(:id).last.action
    refused_by_database do
      ApplicationWindowEvent.insert_all!([{ job_id: @job.id, action: "reopen", reason: " ", actor_id: 1, actor_role: "hr_pic",
                                            created_at: Time.current }])
    end
    post staff_job_portal_reopen_path(@job), params: { reason: "Kuota ditambah", commit: "Reopen" }
    assert_equal ["reopen", "hr_pic", "Kuota ditambah"], @job.application_window_events.order(:id).last.slice(:action, :actor_role, :reason).values
  end

  test "reopen re-checks the preconditions: no reopen while the ad is not approved" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    @job.update_columns(ad_approved_at: nil)
    assert_raises(Portal::WindowChange::Refused) do
      Portal::WindowChange.reopen!(job: @job, actor: staff_user("hr_pic"), reason: "lagi")
    end
  end

  test "a consultant opening on HR's behalf is logged as consultant, never as hr_pic" do
    set_retention
    publish_consent
    consultant = staff_user("consultant")
    sign_in_as consultant
    post staff_job_portal_open_path(@job), params: { commit: "Open portal" }
    event = @job.application_window_events.sole
    assert_equal [consultant.id, "consultant"], [event.actor_id, event.actor_role]
  end

  test "owner and admin cannot open, close or reopen the portal" do
    set_retention
    publish_consent
    %w[owner admin reviewer].each do |role|
      assert_raises(Portal::WindowChange::Refused, role) { Portal::WindowChange.open!(job: @job, actor: staff_user(role)) }
    end
    open_portal(@job)
    %w[owner admin reviewer].each do |role|
      assert_raises(Portal::WindowChange::Refused, role) { Portal::WindowChange.close!(job: @job, actor: staff_user(role)) }
    end
    assert ApplicationWindow.new(@job).open?
  end

  # --- consent (D35) ------------------------------------------------------------------------

  test "the database refuses a candidate application without consent time, without version, or with 0 retention days" do
    open_portal(@job)
    application, = submit!(@job)
    { consent_at: nil, consent_template_id: nil, consent_retention_days: 0 }.each do |column, value|
      error = refused_by_database { JobApplication.where(id: application.id).update_all(column => value) }
      assert_match(/job_applications_consent_recorded/, error.message, column.to_s)
    end
  end

  # The original CHECK read "consent_retention_days > 0". With NULL that expression is NULL, and a
  # CHECK that evaluates to NULL PASSES in SQL, so the database accepted an application stating no
  # retention period (F7). Migration ...07 adds IS NOT NULL; this test guards it.
  test "F7 fixed: the database refuses a candidate application with NO retention days (NULL)" do
    open_portal(@job)
    application, = submit!(@job)
    refused_by_database { JobApplication.where(id: application.id).update_all(consent_retention_days: nil) }
  end

  test "a consent version cannot be edited or deleted once stored, even by raw SQL" do
    template = publish_consent
    purpose = template.purpose
    refused_by_database { ConsentTemplate.where(id: template.id).update_all(purpose: "Tujuan lain") }
    refused_by_database { ConsentTemplate.where(id: template.id).delete_all }
    refused_by_database { ActiveRecord::Base.connection.execute("TRUNCATE consent_templates CASCADE") }
    assert_equal purpose, template.reload.purpose
  end

  test "purpose cannot be emptied: service refuses blank and whitespace, the database refuses whitespace" do
    admin = staff_user("admin")
    assert_raises(Portal::PublishConsent::Invalid) { Portal::PublishConsent.call(params: complete_consent(purpose: " \n "), actor: admin) }
    refused_by_database do
      ConsentTemplate.insert_all!([PortalFactory::COMPLETE_CONSENT.merge(purpose: "   ", version: "x", effective_from: Time.current,
                                                                       created_at: Time.current)])
    end
    assert_equal 0, ConsentTemplate.count
  end

  test "a future consent version is not used before its effective time, and is used from it" do
    open_portal(@job)
    current = ConsentTemplate.in_force
    future = Portal::PublishConsent.call(params: complete_consent(purpose: "Tujuan versi baru", effective_from: 2.days.from_now),
                                         actor: staff_user("admin"))
    lamar_post
    assert_equal current.id, JobApplication.where.not(candidate_id: nil).last.consent_template_id
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    refute_includes response.body, "Tujuan versi baru", "the future text is shown before it applies"

    travel_to future.effective_from + 1.second do
      token = step2_token(@job)
      assert_includes response.body, "Tujuan versi baru", "control: the new text is shown once in force"
      lamar_post(@job, email: "later@uji.example", consent_token: token)
      assert_equal future.id, Candidate.find_by!(email: "later@uji.example").then { |c| JobApplication.find_by!(candidate: c) }.consent_template_id
    end
  end

  test "a new version cannot take effect immediately while one is in force (announced first, Pasal 21(2))" do
    publish_consent
    assert_raises(Portal::PublishConsent::Invalid) { Portal::PublishConsent.call(params: complete_consent(effective_from: Time.current), actor: staff_user("admin")) }
    assert_raises(Portal::PublishConsent::Invalid) { Portal::PublishConsent.call(params: complete_consent(effective_from: 1.day.ago), actor: staff_user("admin")) }
    assert_equal 1, ConsentTemplate.count
  end

  # D35 contract (2026-10-10, test-engine F5/F6): step 2 signs the version and the retention days
  # SHOWN into lamaran[consent_token]; the server stores what the token says.
  test "F5 fixed: the version stored is the version SHOWN, also when a new version takes effect between step 2 and the POST" do
    open_portal(@job)
    shown = ConsentTemplate.in_force
    future = Portal::PublishConsent.call(params: complete_consent(purpose: "Tujuan versi baru", effective_from: 10.minutes.from_now),
                                         actor: staff_user("admin"))
    token = step2_token(@job)
    assert_includes response.body, shown.version
    travel_to future.effective_from + 1.minute do
      lamar_post(@job, consent_token: token)
      assert_response :success
    end
    stored = JobApplication.where.not(candidate_id: nil).sole
    assert_equal shown.id, stored.consent_template_id, "stored as agreeing to #{stored.consent_template.version}, shown #{shown.version}"
  end

  test "F6 fixed: the retention days stored are the days SHOWN, also when the setting changes before submission" do
    open_portal(@job)
    set_retention(30)
    token = step2_token(@job)
    assert_includes response.body, "kept for 30 days"
    set_retention(365)
    lamar_post(@job, consent_token: token)
    assert_response :success
    assert_equal 30, JobApplication.where.not(candidate_id: nil).sole.consent_retention_days
  end

  test "the step-2 token records exactly the version and days printed on that page" do
    open_portal(@job)
    set_retention(45)
    token = step2_token(@job)
    data = shown_by(token)
    printed = response.body[/Text version: ([^<\s]+)/, 1]
    assert_equal [ConsentTemplate.find_by!(version: printed).id, 45], [data["template_id"], data["retention_days"]]
    assert_includes response.body, "kept for 45 days"
  end

  test "a POST without a token, with a tampered token, or with an expired token stores nothing and asks again (422)" do
    open_portal(@job)
    good = step2_token(@job)
    forged = Portal::SubmitApplication.consent_verifier.generate({ "template_id" => ConsentTemplate.in_force.id, "retention_days" => 1 }) + "x"
    tampered = good.sub(/.\z/) { |c| c == "A" ? "B" : "A" }
    [nil, "", tampered, forged].each_with_index do |token, i|
      lamar_post(@job, email: "t#{i}@uji.example", consent_token: token)
      assert_response :unprocessable_entity, "token #{token.inspect[0, 20]}"
      assert_includes response.body, "The terms for the use of your data have changed"
    end
    travel 1.day + 1.minute do
      lamar_post(@job, email: "late@uji.example", consent_token: good)
      assert_response :unprocessable_entity, "a day-old token was accepted"
    end
    assert_equal 0, candidate_count
    lamar_post(@job, consent_token: good)
    assert_response :success, "control: the untouched token is accepted"
  end

  # A token signed for one purpose must not be accepted from another verifier's output.
  test "a value signed by another Rails verifier is not accepted as a consent token" do
    open_portal(@job)
    other = Rails.application.message_verifier(:something_else).generate({ "template_id" => ConsentTemplate.in_force.id, "retention_days" => 30 })
    lamar_post(@job, consent_token: other)
    assert_response :unprocessable_entity
    assert_equal 0, candidate_count
  end

  test "a submission while the retention setting has gone missing is refused and stores nothing, even with a valid token" do
    open_portal(@job)
    token = step2_token(@job)
    SystemSetting.where(key: "retention_days").delete_all
    assert_equal :closed_by_settings, ApplicationWindow.new(@job).state
    lamar_post(@job, consent_token: token)
    assert_response :gone
    assert_equal 0, candidate_count
  end

  test "retention 0 or negative is refused by the setting and could not be stored on an application" do
    assert_raises(Portal::UpdateSetting::Invalid) { set_retention(0) }
    assert_raises(Portal::UpdateSetting::Invalid) { set_retention(-5) }
    assert_nil SystemSetting.retention_days
  end

  # --- D38: no portal while the consent text is incomplete ----------------------------------

  test "G1 fixed: D38 refusal names each [PLACEHOLDER] section that blocks the portal" do
    set_retention
    ConsentTemplate.create!(ConsentTemplate::DRAFT.merge(version: "draft-1", effective_from: 1.hour.ago, created_at: Time.current))
    error = assert_raises(Portal::WindowChange::Refused) { Portal::WindowChange.open!(job: @job, actor: staff_user("hr_pic")) }
    # D38: "the admin sees which lines block it". Every placeholder section must be named.
    ConsentTemplate::SECTIONS.values_at(:controller_identity, :legal_basis, :data_types, :processing_duration, :rights).each do |heading|
      assert_includes error.message, heading, "the refusal does not name the blocking section"
    end
    assert_equal 0, @job.application_window_events.count
  end

  test "D38: an OPEN portal stops accepting the moment a version with a placeholder takes effect, on both steps" do
    open_portal(@job)
    token = step2_token(@job)
    Portal::PublishConsent.call(params: ConsentTemplate::DRAFT.merge(effective_from: 5.minutes.from_now.iso8601), actor: staff_user("admin"))
    travel 6.minutes do
      assert_equal :closed_by_settings, ApplicationWindow.new(@job).state
      get lamar_path(@job.public_code)
      assert_includes response.body, "This vacancy is not accepting applications yet."
      assert_select "form[action*='periksa']", 0
      post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
      assert_response :gone
      lamar_post(@job, consent_token: token)
      assert_response :gone, "a token shown before the placeholder version still stored an application"
    end
    assert_equal 0, candidate_count
  end

  # --- D40a: once S1 has closed, the window counts as closed --------------------------------

  test "D40a: after S1 closes, Lamar says so with no form, and both steps refuse (410) and store nothing" do
    open_portal(@job)
    token = step2_token(@job)
    application, = submit!(@job, email: "awal@uji.example")
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(application, "S1", outcome: "pass", close: false)
    Stages::Close.call(stage: s1.reload)
    assert_equal :closed_by_stage, ApplicationWindow.new(@job).state
    get lamar_path(@job.public_code)
    assert_includes response.body, "CV screening for this vacancy has closed."
    assert_select "form", 0
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    assert_response :gone
    lamar_post(@job, email: "telat@uji.example", knockout: answers_for(@job, "tidak"), consent_token: token)
    assert_response :gone
    lamar_post(@job, email: "telat2@uji.example", phone: "1", consent_token: token)
    assert_response :gone, "invalid data on a stage-closed portal is answered with the form"
    assert_equal 1, candidate_count
  end

  # D40a makes the window closed while S1 is closed. Before the G4 fix "Reopen" there appended
  # a reopen event and the screen said "Applicant portal reopened." while nobody could apply.
  test "G4 fixed: reopening after S1 closed is refused with the reason, not reported as 'dibuka lagi'" do
    open_portal(@job)
    application, = submit!(@job)
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(application, "S1", outcome: "pass", close: false)
    Stages::Close.call(stage: s1.reload)
    sign_in_as staff_user("hr_pic")
    post staff_job_portal_reopen_path(@job), params: { reason: "Tambah pelamar", commit: "Reopen" }
    follow_redirect!
    refute_includes response.body, "Applicant portal reopened.", "the screen claims a reopen that admits nobody"
    assert_equal :closed_by_stage, ApplicationWindow.new(@job).state
  end
end
