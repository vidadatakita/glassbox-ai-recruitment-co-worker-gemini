require "test_helper"
require_relative "portal_engine_support"

# Hunt items 1 (role matrix) and 8 (house hard rules) of brief 02.
#
# Role matrix, from blueprint §1.2 and the feature record §2: approve ad = hr_pic; open / close /
# reopen = hr_pic or consultant; schedule, upload offer, mark follow-up = consultant; answer an
# objection = consultant or reviewer; settings and consent text = admin; work queue (screen 6)
# = consultant (slice plan §2). Each refusal has a control: the allowed role succeeds.
#
# House rules: every page a candidate or staff member can reach, in every state that adds a
# form, is checked on the rendered HTML; and the important forms are SUBMITTED as a browser
# would (every successful control plus the pressed button), so the button's name/value is shown
# to reach the controller and the action to take effect.
class EnginePortalStaffAndFormsTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  STAFF_ROLES = %w[owner hr_pic consultant reviewer admin].freeze

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @job = portal_job
    open_portal(@job)
  end

  def as(role) = sign_in_as(staff_user(role))

  # An application with a closed S1 elimination and an open objection, a passed S5 and an
  # accepted offer awaiting follow-up, an appointment asking for another time, a failed mail and
  # a link request: every work-queue section populated.
  def populated!
    @rina, @rina_token = submit!(@job)
    @sari, @sari_token = submit!(@job, name: "Sari Dewi", email: "sari@uji.example", phone: "081311112222")
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(@rina, "S1", outcome: "pass", close: false)
    sari_p1 = decide_stage!(@sari, "S1", outcome: "eliminate", score: 30, close: false)
    @tari, @tari_token = submit!(@job, name: "Tari Lestari", email: "tari@uji.example", phone: "081355556666")
    decide_stage!(@tari, "S1", outcome: "eliminate", score: 25, close: false)
    Stages::Close.call(stage: s1.reload)
    @objection = Portal::CandidateActions.new(@sari).object!(sari_p1.id, "Saya memenuhi syarat")
    s5 = stage_of(@job, "S5")
    Stages::Open.call(stage: s5)
    p5 = enter_stage_by_choice!(@rina, s5) # D63 strict entry: Rina enters S5 through a person's Lanjut
    @appointment = p5.create_appointment!(starts_at: 3.hours.from_now, ends_at: 4.hours.from_now, mode: "onsite",
                                          place_or_link: "Ruang Rapat 2", contact: "Dewi", confirmation: "reschedule_requested",
                                          reschedule_reason: "Bentrok ujian")
    @mail_failure = MailDelivery.create!(job_application: @rina, kind: "status_link", status: "failed",
                                         error_class: "Errno::ECONNREFUSED", error_message: "refused")
    @link_request = LinkRequest.create!(job_code: @job.public_code, contact: "hilang@uji.example")
    # D40a: @job's S1 is now closed, so its portal admits nobody. Lamar pages and the window
    # buttons are exercised on a second, open job.
    @job2 = portal_job
    open_portal(@job2)
  end

  def accepted_offer!
    s5 = stage_of(@job, "S5")
    participation = @rina.participations.find_by!(stage: s5)
    participation.update!(attendance: "attended")
    add_score(participation, 88)
    decide!(participation, outcome: "pass")
    Stages::Close.call(stage: s5.reload)
    offer = upload_offer!(@rina)
    Portal::CandidateActions.new(@rina).respond_to_offer!(offer.id, response: "accepted")
    offer
  end

  # --- role matrix --------------------------------------------------------------------------

  test "approve ad: only hr_pic; the approval records who" do
    job = portal_job
    job.update_columns(ad_approved_at: nil, ad_approved_by_id: nil, ad_text: "Tentang posisi ini\nIklan uji.")
    (STAFF_ROLES - ["hr_pic"]).each do |role|
      as role
      patch approve_ad_staff_job_path(job), params: { commit: "Approve job ad" }
      assert_nil job.reload.ad_approved_at, "#{role} approved the ad"
    end
    as "hr_pic"
    patch approve_ad_staff_job_path(job), params: { commit: "Approve job ad" }
    assert_equal staff_user("hr_pic").id, job.reload.ad_approved_by_id, "control"
  end

  test "schedule an appointment: only consultant" do
    populated!
    participation = @rina.participations.find_by!(stage: stage_of(@job, "S5"))
    @appointment.update!(confirmation: "pending")
    start = 2.days.from_now.change(hour: 9)
    params = { appointment: { starts_at: start.strftime("%Y-%m-%dT%H:%M"), ends_at: (start + 1.hour).strftime("%Y-%m-%dT%H:%M"),
                              mode: "video", place_or_link: "https://meet.example/x", contact: "Dewi" }, commit: "Simpan perubahan jadwal" }
    (STAFF_ROLES - ["consultant"]).each do |role|
      as role
      patch staff_appointment_path(@appointment), params: params
      assert_equal "onsite", @appointment.reload.mode, "#{role} changed a schedule"
    end
    as "consultant"
    patch staff_appointment_path(@appointment), params: params
    assert_equal "video", @appointment.reload.mode, "control"
    assert_equal participation.id, @appointment.participation_id
  end

  test "mark the offer-to-start follow-up: only consultant (same before_action as the upload)" do
    populated!
    offer = accepted_offer!
    (STAFF_ROLES - ["consultant"]).each do |role|
      as role
      post staff_offer_followed_up_path(offer), params: { commit: "Sudah dihubungi" }
      assert_nil offer.reload.followed_up_at, "#{role} marked the follow-up"
    end
    as "consultant"
    post staff_offer_followed_up_path(offer), params: { commit: "Sudah dihubungi" }
    assert offer.reload.followed_up_at, "control"
  end

  test "answer an objection: only consultant or reviewer" do
    populated!
    %w[owner hr_pic admin].each do |role|
      as role
      post staff_objection_answer_path(@objection), params: { outcome: "upheld", answer: "Ya", commit: "Kirim jawaban" }
      assert_nil @objection.reload.answered_at, "#{role} answered an objection"
    end
    as "reviewer"
    post staff_objection_answer_path(@objection), params: { outcome: "not_upheld", answer: "Ditinjau", commit: "Kirim jawaban" }
    assert_equal staff_user("reviewer").id, @objection.reload.answered_by_id, "control"
  end

  test "settings and consent text: only admin" do
    (STAFF_ROLES - ["admin"]).each do |role|
      as role
      patch staff_settings_path, params: { key: "retention_days", value: "999", commit: "Simpan" }
      post consent_staff_settings_path, params: { consent: ConsentTemplate::DRAFT.merge(effective_from: 2.days.from_now.iso8601) }
    end
    assert_equal 30, SystemSetting.retention_days
    assert_equal 1, ConsentTemplate.count
  end

  # Screen 6 is the consultant's queue (slice plan §2). Marking a mail failure "handled" removes
  # it from the only place an operator sees it; before the F11 fix any logged-in role could.
  test "F11 fixed: only the consultant can mark a failed email or a link request as handled" do
    populated!
    %w[owner hr_pic reviewer admin].each do |role|
      as role
      post handle_mail_failure_staff_work_queue_path(@mail_failure), params: { commit: "Sudah ditangani" }
      post handle_link_request_staff_work_queue_path(@link_request), params: { commit: "Tandai selesai" }
    end
    assert_nil @mail_failure.reload.handled_at, "a non-consultant hid a failed email from the work queue"
    assert_nil @link_request.reload.handled_at, "a non-consultant closed a candidate's link request"
  end

  test "F12 fixed: a failed email marked handled records who handled it" do
    populated!
    as "consultant"
    post handle_mail_failure_staff_work_queue_path(@mail_failure), params: { commit: "Sudah ditangani" }
    assert @mail_failure.reload.handled_at
    assert_equal staff_user("consultant").id, @mail_failure.handled_by_id
  end

  # Blueprint §1.2: Admin = clients, packages, job library, templates, users. No candidate work.
  test "F13 fixed / D40d: owner, hr_pic, consultant and reviewer get the CV; admin cannot open the candidate or the CV" do
    populated!
    %w[owner hr_pic consultant reviewer].each do |role|
      as role
      get cv_staff_application_path(@rina)
      assert_equal "application/pdf", response.media_type, "control: #{role} gets the CV"
    end
    as "admin"
    get cv_staff_application_path(@rina)
    refute_equal "application/pdf", response.media_type, "admin downloaded a candidate CV"
    get staff_application_path(@rina)
    refute_includes response.body, "rina@uji.example", "admin sees the candidate's email and phone"
  end

  test "every staff action refuses a logged-out request and a candidate's link session" do
    populated!
    get candidate_status_path(@rina_token) # a candidate session cookie in this browser
    requests = [
      -> { get staff_jobs_path }, -> { get staff_job_path(@job) }, -> { get staff_application_path(@rina) },
      -> { get cv_staff_application_path(@rina) }, -> { get staff_work_queue_path }, -> { get staff_settings_path },
      -> { post staff_job_portal_close_path(@job) }, -> { post staff_objection_answer_path(@objection), params: { outcome: "upheld", answer: "x" } },
      -> { post handle_mail_failure_staff_work_queue_path(@mail_failure) }, -> { patch staff_settings_path, params: { key: "retention_days", value: "5" } }
    ]
    requests.each do |request|
      request.call
      assert_redirected_to new_session_path
    end
    assert_equal 1, @job.application_window_events.count, "a logged-out request wrote a window event"
    assert_nil @objection.reload.answered_at
    assert_nil @mail_failure.reload.handled_at
  end

  # --- D39 / D40 ------------------------------------------------------------------------------

  test "D39: step 2 shows the open layer, then the disclosure button directly above the unticked checkbox, and every detail word for word" do
    consent = ConsentTemplate.in_force
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    doc = Nokogiri::HTML(response.body)
    box = doc.at_css(".consent")
    details = doc.at_css("[data-consent-details]")
    assert details, "no details block"
    open_text = (box.text.squish.split(details.text.squish).first || "")
    %i[controller_identity legal_basis purpose rights].each do |field|
      assert_includes open_text, consent.public_send(field), "#{field} is not in the open layer"
    end
    assert_includes open_text, "kept for 30 days"
    ConsentTemplate::DETAIL_SECTIONS.each do |field|
      assert_equal consent.public_send(field), details.at_css("[data-consent-field='#{field}']")&.text, "#{field} not word for word"
    end
    assert_equal ConsentTemplate::SECTIONS.keys.sort, (%i[controller_identity legal_basis purpose rights] + ConsentTemplate::DETAIL_SECTIONS).sort,
                 "a Pasal 21(1) section is in neither layer"
    assert_empty doc.css(".consent [aria-hidden], [data-consent-details][hidden], [data-consent-details][style*='none']"),
                 "consent text is hidden from screen readers or without JavaScript"
    toggle = doc.at_css("[data-consent-toggle]")
    assert_equal ["button", nil], [toggle["type"], toggle["disabled"]], "the disclosure control submits or is disabled"
    checkbox_label = doc.at_css("input[name='lamaran[consent]']").ancestors("label").first
    nxt = toggle.next_element
    assert_equal checkbox_label, nxt, "the disclosure button is not directly above the checkbox"
    refute doc.at_css("input[name='lamaran[consent]']").key?("checked"), "consent pre-ticked"
  end

  test "D40b: GET of the confirmation page withdraws nothing; a revoked link cannot reach it" do
    application, token = submit!(@job)
    get candidate_status_confirm_withdraw_path(token)
    assert_response :success
    assert_nil application.reload.consent_withdrawn_at
    Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example")
    get candidate_status_confirm_withdraw_path(token)
    assert_response :not_found
  end

  test "D40c: whoever decided the participation cannot answer its objection; another reviewer can" do
    application, token = submit!(@job)
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decider = staff_user("reviewer")
    participation = application.participations.find_by!(stage: s1)
    Decision.create!(participation:, outcome: "eliminate", basis: "manual", reason_code: "below_threshold", note: "Tidak sesuai",
                     decided_by_id: decider.id, decided_at: Time.current)
    Stages::Close.call(stage: s1.reload)
    post candidate_status_object_path(token, participation.id), params: { text: "Saya memenuhi syarat", commit: "Kirim keberatan" }
    objection = Objection.sole
    sign_in_as decider
    post staff_objection_answer_path(objection), params: { outcome: "not_upheld", answer: "Tetap", commit: "Kirim jawaban" }
    assert_nil objection.reload.answered_at, "the person who decided answered the objection against their own decision"
    other = staff_user("reviewer", email: "reviewer2@uji.example")
    sign_in_as other
    post staff_objection_answer_path(objection), params: { outcome: "not_upheld", answer: "Sudah ditinjau ulang", commit: "Kirim jawaban" }
    assert_equal other.id, objection.reload.answered_by_id, "control: another reviewer answers"
  end

  test "D40c: a consultant who superseded an earlier decision also counts as having decided" do
    application, token = submit!(@job)
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    consultant = staff_user("consultant")
    participation = application.participations.find_by!(stage: s1)
    first = Decision.create!(participation:, outcome: "pass", basis: "manual", reason_code: "x", note: "awal",
                             decided_by_id: consultant.id, decided_at: Time.current)
    Decision.create!(participation:, outcome: "eliminate", basis: "manual", reason_code: "below_threshold", note: "koreksi",
                     decided_by_id: staff_user("reviewer").id, decided_at: Time.current, supersedes: first)
    Stages::Close.call(stage: s1.reload)
    objection = Portal::CandidateActions.new(application).object!(participation.id, "Keliru")
    assert_raises(Objection::Refused) { objection.answer!(user: consultant, outcome: "upheld", answer: "Ya") }
  end

  test "D40e: no appointment can be created or changed for a withdrawn application" do
    populated!
    @appointment.update!(confirmation: "pending")
    Portal::CandidateActions.new(@rina).withdraw_consent!
    as "consultant"
    start = 2.days.from_now.change(hour: 9)
    params = { appointment: { starts_at: start.strftime("%Y-%m-%dT%H:%M"), ends_at: (start + 1.hour).strftime("%Y-%m-%dT%H:%M"),
                              mode: "video", place_or_link: "https://meet.example/x", contact: "Dewi" } }
    patch staff_appointment_path(@appointment), params: params
    assert_equal "onsite", @appointment.reload.mode, "a withdrawn applicant's schedule was changed"
    assert_no_difference -> { Appointment.count } do
      # D63 strict entry: Tari was eliminated at S1, so no person's Lanjut can put her in S5; the
      # create is tried on her own (S1) participation, which the withdrawal check refuses first.
      tari_s1 = @tari.participations.find_by!(stage: stage_of(@job, "S1"))
      Portal::CandidateActions.new(@tari).withdraw_consent!
      post staff_participation_appointments_path(tari_s1), params: params
    end
  end

  test "free text and codes typed by candidates and staff never reach the log" do
    populated!
    io = StringIO.new
    old = Rails.logger
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io))
    Rails.logger = logger
    ActionController::Base.logger = logger
    begin
      @appointment.update!(confirmation: "pending")
      post candidate_status_reschedule_path(@rina_token, @appointment.id), params: { reason: "Ujian-skripsi-Zx41" }
      post candidate_status_object_path(@tari_token, @tari.participations.first.id), params: { text: "Keberatan-rahasia-Qp93" }
      post candidate_status_unlock_offer_path(@rina_token), params: { code: "918273" }
      as "reviewer"
      post staff_objection_answer_path(@objection), params: { outcome: "not_upheld", answer: "Jawaban-staf-Lm27" }
    ensure
      Rails.logger = old
      ActionController::Base.logger = old
    end
    log = io.string
    assert_match(/Parameters:/, log, "control: the parameters line was logged")
    ["Ujian-skripsi-Zx41", "Keberatan-rahasia-Qp93", "918273", "Jawaban-staf-Lm27", @rina_token, @tari_token].each do |secret|
      refute_includes log, secret
    end
  end

  # --- house rules on rendered pages ---------------------------------------------------------

  test "house rules on every candidate page and state" do
    populated!
    pages = {}
    get lamar_path(@job2.public_code); pages["lamar step 1"] = response.body
    post lamar_check_path(@job2.public_code), params: { knockout: answers_for(@job2) }; pages["lamar step 2"] = response.body
    post lamar_path(@job2.public_code), params: { knockout: answers_for(@job2), lamaran: { name: "", consent: "0", consent_token: shown_consent_token } }
    pages["lamar errors"] = response.body
    post lamar_path(@job2.public_code), params: { knockout: answers_for(@job2), lamaran: application_params(@job2).except(:knockout) }
    pages["lamar consent token missing"] = response.body
    post lamar_check_path(@job2.public_code), params: { knockout: answers_for(@job2, "tidak") }; pages["not eligible"] = response.body
    get lamar_path(@job.public_code); pages["lamar closed by stage"] = response.body
    get new_link_request_path; pages["minta link"] = response.body
    post link_requests_path, params: { job_code: "x", email: "x@uji.example" }; pages["link request sent"] = response.body
    get candidate_status_path("tidak-berlaku"); pages["invalid link"] = response.body
    @appointment.update!(confirmation: "pending")
    get candidate_status_path(@rina_token); pages["status with appointment"] = response.body
    get candidate_status_path(@sari_token); pages["status with result and objection"] = response.body
    get candidate_status_path(@tari_token); pages["status with objection form"] = response.body
    @objection.update!(outcome: "not_upheld", answer: "Sudah ditinjau", answered_at: Time.current, answered_by_id: 1)
    get candidate_status_path(@sari_token); pages["status with answered objection"] = response.body
    offer = accepted_offer!
    OfferDocument.where(id: offer.id).update_all(response: nil, responded_at: nil)
    get candidate_status_path(@rina_token); pages["status offer locked"] = response.body
    post candidate_status_offer_code_path(@rina_token)
    post candidate_status_unlock_offer_path(@rina_token), params: { code: last_code_for("rina@uji.example") }
    get candidate_status_path(@rina_token); pages["status offer unlocked"] = response.body
    Portal::WindowChange.close!(job: @job2, actor: staff_user("hr_pic"))
    get lamar_path(@job2.public_code); pages["lamar closed by hr"] = response.body
    get candidate_status_confirm_withdraw_path(@sari_token); pages["confirm withdrawal"] = response.body
    post candidate_status_withdraw_path(@sari_token); pages["withdrawn"] = response.body

    assert_includes pages["lamar consent token missing"], "The terms for the use of your data have changed", "control: the 422 page"
    assert_includes pages["lamar closed by stage"], "CV screening for this vacancy has closed.", "control"
    assert_includes pages["confirm withdrawal"], "value=\"Yes, withdraw my application\"", "control"

    assert_includes pages["status offer unlocked"], "value=\"Accept\"", "control: the unlocked page has the answer forms"
    assert_includes pages["status with result and objection"], "Your objection is being reviewed", "control: the open objection is shown"
    assert_includes pages["status with objection form"], "value=\"Send objection\"", "control: the objection form is rendered"
    pages.each { |where, html| assert_engine_house_rules(html, where) }
  end

  test "house rules on every staff page, for every role, with every work-queue section populated" do
    populated!
    accepted_offer!
    STAFF_ROLES.each do |role|
      as role
      [staff_jobs_path, staff_job_path(@job), staff_application_path(@rina), staff_application_path(@sari),
       staff_work_queue_path, staff_settings_path].each do |path|
        get path
        follow_redirect! if response.redirect?
        assert_response :success, "#{role} #{path}"
        assert_engine_house_rules(response.body, "#{role} #{path}")
      end
    end
    as "consultant"
    get staff_work_queue_path
    %w[Handled Mark\ done Send\ answer Contacted].each do |label|
      assert_includes response.body, "value=\"#{label}\"", "control: the work queue renders '#{label}'"
    end
  end

  test "submit guard never disables a button (static check of the shipped JavaScript)" do
    source = Rails.root.join("app/javascript/submit_guard.js").read
    code = source.lines.reject { |l| l.strip.start_with?("//") }.join
    refute_match(/disabled|disable-with|submits-with|\.submit\(\)/, code)
    Dir[Rails.root.join("app/{views,javascript,helpers}/**/*")].select { |f| File.file?(f) }.each do |file|
      # Comments that WARN against these patterns are allowed; code is not.
      text = File.readlines(file).reject { |l| l.strip.start_with?("//", "#", "<%#") }.join
      refute_match(/Terapkan/i, text, file)
      refute_match(/data-disable-with|disable_with:/, text, file)
    end
  end

  # --- the pressed button reaches the controller -------------------------------------------

  test "candidate forms submitted as a browser would: the button's name/value arrives and the action happens" do
    populated!
    get lamar_path(@job2.public_code)
    params = press("Next", @job2.knockout_questions.to_h { |q| ["knockout[#{q.id}]", "ya"] })
    assert_equal "Next", params["commit"]
    params = press("Send application", "lamaran[name]" => "Tono Wijaya", "lamaran[phone]" => "081277778888",
                                    "lamaran[email]" => "tono@uji.example", "lamaran[consent]" => "1", "lamaran[cv]" => pdf_upload)
    assert_equal "Send application", params["commit"]
    assert Candidate.exists?(email: "tono@uji.example"), "the browser-shaped application was stored"
    assert_equal ConsentTemplate.in_force.id, JobApplication.joins(:candidate).find_by!(candidates: { email: "tono@uji.example" }).consent_template_id

    @appointment.update!(confirmation: "pending")
    get candidate_status_path(@rina_token)
    assert_equal "Confirm attendance", press("Confirm attendance")["commit"]
    assert_equal "confirmed", @appointment.reload.confirmation

    get candidate_status_path(@sari_token)
    Objection.where(id: @objection.id).update_all(answered_at: Time.current, outcome: "not_upheld", answer: "x", answered_by_id: 1)
    get candidate_status_path(@sari_token)
    refute_includes response.body, "value=\"Send objection\"", "an answered objection shows the answer, not a new form"

    offer = accepted_offer!
    OfferDocument.where(id: offer.id).update_all(response: nil, responded_at: nil)
    get candidate_status_path(@rina_token)
    press("Send code to my e-mail")
    follow_redirect!
    press("Open offer", "code" => last_code_for("rina@uji.example"))
    follow_redirect!
    params = press("Decline", "reason" => "Lokasi terlalu jauh")
    assert_equal ["Decline", "declined"], [params["commit"], params["response"]]
    assert_equal ["declined", "Lokasi terlalu jauh"], [offer.reload.response, offer.response_reason]

    get candidate_status_path(@rina_token)
    follow = Nokogiri::HTML(response.body).at_css("a[href$='/withdraw-consent']")
    assert follow, "the status page links to the withdrawal confirmation (D40b)"
    get follow["href"]
    assert_nil @rina.reload.consent_withdrawn_at, "opening the confirmation page withdrew the application"
    assert_equal "Yes, withdraw my application", press("Yes, withdraw my application")["commit"]
    assert @rina.reload.consent_withdrawn_at
  end

  test "staff forms submitted as a browser would: the button's name/value arrives and the action happens" do
    populated!
    as "consultant"
    get staff_job_path(@job2)
    assert_equal "Close portal", press("Close portal", "reason" => "Cukup")["commit"]
    assert_equal :closed_by_hr, ApplicationWindow.new(@job2).state
    follow_redirect!
    assert_equal "Reopen", press("Reopen", "reason" => "Tambah kuota", "quota" => "50")["commit"]
    assert_equal ["reopen", 50], @job2.application_window_events.order(:id).last.slice(:action, :quota).values
    assert ApplicationWindow.new(@job2).open?

    get staff_work_queue_path
    assert_equal "Send answer", press("Send answer", "outcome" => "upheld", "answer" => "Akan ditinjau ulang")["commit"]
    assert_equal "upheld", @objection.reload.outcome

    as "admin"
    get staff_settings_path
    params = press("Save as new version", "consent[effective_from]" => 3.days.from_now.strftime("%Y-%m-%dT%H:%M"))
    assert_equal "Save as new version", params["commit"]
    assert_equal 2, ConsentTemplate.count
  end
end
