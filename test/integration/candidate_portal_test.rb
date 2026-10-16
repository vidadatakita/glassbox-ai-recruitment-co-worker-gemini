require "test_helper"

# Candidate pages through real requests: the server refusal, what the rendered HTML may and may
# not contain (BP §3.6 D), the status-link controls (D36) and the house form rules (§5.3).
class CandidatePortalTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @job = portal_job
  end

  # §5.3 / global hard rules, asserted on the rendered page.
  def assert_house_form_rules(html = response.body)
    doc = Nokogiri::HTML(html)
    doc.css("form").each do |form|
      assert_empty form.css("form"), "a form is nested inside another form"
    end
    assert_empty doc.css("button[disabled], input[type=submit][disabled]"), "a submit button is disabled"
    assert_empty doc.css("[data-disable-with], [data-turbo-submits-with]"), "a submit guard disables or relabels a button"
  end

  test "Lamar step 1 shows the trust block and only the knockout questions" do
    open_portal(@job)
    get lamar_path(@job.public_code)
    assert_response :success
    assert_includes response.body, "GlassBox never asks for any payment."
    assert_includes response.body, "1500 630"
    assert_includes response.body, company.contact_email
    refute_includes response.body, "Verified by GlassBox", "the verified line is off by default (ONP-14, Q10)"
    assert_select "input[type=file]", 0, "no personal data is asked in step 1"
    assert_house_form_rules
  end

  test "the verified line appears only when the setting is on" do
    open_portal(@job)
    Portal::UpdateSetting.call(key: "verified_line", value: "1", actor: staff_user("admin"))
    get lamar_path(@job.public_code)
    assert_includes response.body, "Verified by GlassBox"
  end

  test "a confidential job never shows the company's name, address or email (G1)" do
    job = portal_job(confidential: true)
    open_portal(job)
    get lamar_path(job.public_code)
    assert_includes response.body, "Company name withheld"
    [company.name, company.address, company.contact_email].each { |text| refute_includes response.body, text }
  end

  test "a knockout 'No' (stored value tidak) in step 1 stops politely and stores nothing" do
    open_portal(@job)
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job).merge(@job.knockout_questions.first.id.to_s => "tidak") }
    assert_response :success
    assert_includes response.body, "We have not stored any data"
    assert_equal 0, JobApplication.count
  end

  test "step 2 shows the consent with the retention days and the text version" do
    open_portal(@job)
    set_retention(90)
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    assert_includes response.body, "kept for 90 days after the vacancy closes"
    assert_includes response.body, ConsentTemplate.in_force.version
    ConsentTemplate::SECTIONS.each_value { |heading| assert_includes response.body, heading }
    assert_house_form_rules
  end

  test "a POST to a closed window is refused by the server and stores nothing" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
                                                 lamaran: application_params(@job).except(:knockout) }
    assert_response :gone
    assert_includes response.body, "This vacancy has closed"
    assert_equal 0, JobApplication.count
  end

  # Interaction review 2026-10-10: the error is shown AT the field, the input keeps what was
  # typed, and the page says the CV must be chosen again (it is never stored before submission).
  test "a wrong phone is marked at its field, typed values are kept, and the CV re-pick is said" do
    open_portal(@job)
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
                                                 lamaran: application_params(@job, phone: "12345").except(:knockout) }
    assert_response :unprocessable_entity
    assert_select "#lamaran_phone[aria-invalid=true][aria-describedby~=lamaran_phone-error]"
    assert_select "#lamaran_phone-error", text: "The WhatsApp number is not valid. Example: 0812 3456 7890."
    assert_select "#lamaran_name[value=?]", "Rina Pratiwi"
    assert_select "#lamaran_cv-error", text: /choose your CV again/
    assert_equal 0, JobApplication.count
    assert_house_form_rules
  end

  test "step 2 asks for the CV natively, with the page's own button text, and checks the phone before sending" do
    open_portal(@job)
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    assert_select "#lamaran_cv[required][accept*=pdf]"
    assert_select ".file-pick__button", text: "Choose file"
    assert_select "#lamaran_phone[required][pattern]"
    assert_select "input[name='lamaran[consent]'][required]"
    refute_includes response.body, "Six fields"
  end

  # The signed consent token from the step-2 page, as a browser would send it back.
  def lamar_form_token
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    Nokogiri::HTML(response.body).at_css("input[name='lamaran[consent_token]']")&.[]("value")
  end

  test "a submission without the consent the page showed is refused with a message and stores nothing (D35)" do
    open_portal(@job)
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
                                                 lamaran: application_params(@job).except(:knockout) }
    assert_response :unprocessable_entity
    assert_includes response.body, "The terms for the use of your data have changed"
    assert_equal 0, JobApplication.count
  end

  # D39 (2026-10-10): the consent layers, the checkbox and the disclosure control.
  test "consent: details carry the template's exact words, the checkbox starts unticked, the toggle sits above it" do
    open_portal(@job)
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    consent = ConsentTemplate.in_force
    doc = Nokogiri::HTML(response.body)
    ConsentTemplate::DETAIL_SECTIONS.each do |field|
      assert_equal consent.public_send(field), doc.at_css("[data-consent-field=#{field}]")&.text, "#{field} must be word for word"
    end
    assert_includes doc.at_css(".consent").text, consent.legal_basis
    assert_includes doc.at_css(".consent").text, consent.rights
    details = doc.at_css("[data-consent-details]")
    assert_nil details["aria-hidden"], "never aria-hidden"
    refute_match(/hidden|collapsed/, details["class"].to_s + details.to_h.keys.join(" "), "rendered expanded without JavaScript")
    checkbox = doc.at_css("input[name='lamaran[consent]']")
    assert_nil checkbox["checked"], "unticked by default"
    toggle = doc.at_css("[data-consent-toggle]")
    assert_equal "button", toggle["type"]
    assert_equal "consent-check", toggle.next_element["class"].split.first, "the toggle sits directly above the checkbox"
  end

  test "consent: submitting without the tick gives a field error at the checkbox, and the button is never disabled" do
    open_portal(@job)
    token = lamar_form_token
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job),
                                                 lamaran: application_params(@job, consent: "0", consent_token: token).except(:knockout) }
    assert_response :unprocessable_entity
    assert_select "#lamaran_consent-error", text: "You need to agree to the use of your data to apply."
    assert_select "button[type=submit][value='Send application']:not([disabled])"
    assert_equal 0, JobApplication.count
  end

  test "consent: the version and retention days SHOWN are the ones stored, across a change in between (D35)" do
    open_portal(@job)
    set_retention(30)
    token = lamar_form_token
    shown = ConsentTemplate.in_force
    set_retention(365)
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job), lamaran: application_params(@job, consent_token: token).except(:knockout) }
    application = JobApplication.last
    assert_equal [shown.id, 30], [application.consent_template_id, application.consent_retention_days]
  end

  test "candidate pages load only their own scripts: no Turbo, no Stimulus (perf baseline 2026-10-10)" do
    open_portal(@job)
    get lamar_path(@job.public_code)
    scripts = Nokogiri::HTML(response.body).css("script").map { |s| "#{s['src']} #{s['type']} #{s.text}" }.join("\n")
    refute_match(/turbo|stimulus|importmap/i, scripts)
    assert_select "script[src*=submit_guard]"
  end

  test "a full application returns the private status link once" do
    open_portal(@job)
    token = lamar_form_token
    assert token.present?, "step 2 carries the signed consent token"
    post lamar_path(@job.public_code, ch: "ig"), params: { knockout: answers_for(@job),
                                                           lamaran: application_params(@job, consent_token: token).except(:knockout) }
    assert_response :success
    assert_includes response.body, "We have received your application."
    application = JobApplication.last
    assert_equal "ig", application.channel_code
    assert application.cv.attached?
    assert_house_form_rules
  end

  test "the status page shows no score, rank or threshold, and never another candidate" do
    open_portal(@job)
    application, token = submit!(@job)
    other, = submit!(@job, name: "Budi Santoso", email: "budi@uji.example")
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    [application, other].each do |app|
      participation = app.participations.find_by!(stage: s1)
      participation.update!(attendance: "attended")
      add_score(participation, 73.4)                 # distinctive, so no date can mask it
      decide!(participation, outcome: "pass")
    end
    Stages::Close.call(stage: s1)

    get candidate_status_path(token)
    assert_response :success
    body = response.body
    assert_includes body, "CV screening: passed"
    refute_includes body, "73.4"
    refute_includes body, "73,4"
    # The S1 threshold is 60 in this fixture; no form of it may appear (the engine's mutant M32
    # printed "60" and the old check, which only refuted "60.0", stayed green).
    text = Nokogiri::HTML(body).at("body").text
    refute_match(/\b60([.,]0)?\b/, text, "the threshold")
    refute_includes body, "Budi", "another candidate"
    refute_match(/\b(rank|score|threshold|peringkat|skor|nilai)\b/i, body)
    assert_house_form_rules
  end

  test "after a 'not passed', later steps and the offer read 'Not continued', never 'Waiting'" do
    open_portal(@job)
    application, token = submit!(@job)
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    participation = application.participations.find_by!(stage: s1)
    participation.update!(attendance: "attended")
    add_score(participation, 41)
    decide!(participation, outcome: "eliminate", reason_code: "below_threshold")
    Stages::Close.call(stage: s1)
    get candidate_status_path(token)
    assert_includes response.body, "CV screening: not passed"
    refute_includes response.body, "Waiting for the previous stage"
    assert_includes response.body, "Not continued"
    assert_includes response.body, "Raise an objection"
  end

  test "while S1 is closed the Lamar page says so before any form, and a POST is refused with 410 (D40)" do
    open_portal(@job)
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    Stages::Close.call(stage: s1)
    get lamar_path(@job.public_code)
    assert_includes response.body, "CV screening for this vacancy has closed."
    assert_select "form", 0
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job), lamaran: application_params(@job).except(:knockout) }
    assert_response :gone
    assert_equal 0, JobApplication.count
  end

  test "a consent text with a [PLACEHOLDER] keeps the portal from accepting, and says so (D38)" do
    open_portal(@job)
    ConsentTemplate.create!(ConsentTemplate::DRAFT.merge(version: "draft-uji", effective_from: 1.minute.ago, created_at: Time.current))
    get lamar_path(@job.public_code)
    assert_includes response.body, "This vacancy is not accepting applications yet."
    assert_select "form", 0
  end

  test "withdrawal takes one confirmation step; the confirm button is a real, enabled submit (D40)" do
    open_portal(@job)
    _application, token = submit!(@job)
    get candidate_status_path(token)
    assert_select "a[href=?]", candidate_status_confirm_withdraw_path(token)
    get candidate_status_confirm_withdraw_path(token)
    assert_select "button[type=submit][name=commit][value=?]:not([disabled])", "Yes, withdraw my application"
    assert OneTimeLink.live("candidate_status", token), "opening the confirmation does not withdraw"
    post candidate_status_withdraw_path(token), params: { commit: "Yes, withdraw my application" }
    assert_nil OneTimeLink.live("candidate_status", token)
  end

  test "a tampered or unknown token gets 'This link is not valid' and nothing else" do
    open_portal(@job)
    _application, token = submit!(@job)
    get candidate_status_path(token.reverse)
    assert_response :not_found
    assert_includes response.body, "This link is not valid."
    refute_includes response.body, "Rina"
  end

  test "every open of a status link is logged (D36)" do
    open_portal(@job)
    _application, token = submit!(@job)
    assert_difference -> { LinkOpen.count }, 2 do
      2.times { get candidate_status_path(token) }
    end
  end

  test "withdrawal kills the link immediately" do
    open_portal(@job)
    _application, token = submit!(@job)
    post candidate_status_withdraw_path(token), params: { commit: "Yes, withdraw my application" }
    assert_includes response.body, "We have received your withdrawal of consent."
    get candidate_status_path(token)
    assert_response :not_found
  end

  test "the offer tab and PDF refuse without the emailed code, and open with it" do
    open_portal(@job)
    application, token = submit!(@job)
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s5)
    participation = enter_stage_by_choice!(application, s5, attendance: "attended")
    add_score(participation, 90)
    decide!(participation, outcome: "pass")
    Stages::Close.call(stage: s5)
    offer = Portal::UploadOffer.call(application:, actor: staff_user("consultant"),
                                     params: { pdf: pdf_upload, start_at: "2026-11-17 08:00",
                                               valid_until: 20.days.from_now.to_date.iso8601, day_one_notes: "Bawa KTP." })

    get candidate_status_offer_pdf_path(token, offer.id)
    assert_redirected_to candidate_status_path(token, anchor: "penawaran")
    post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted" }
    assert_nil offer.reload.response, "no answer without the code"

    post candidate_status_offer_code_path(token)
    code = ActionMailer::Base.deliveries.last.body.to_s[/\b\d{6}\b/]
    assert code, "the code email was sent"
    post candidate_status_unlock_offer_path(token), params: { code: "000000" == code ? "111111" : "000000" }
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :redirect, "a wrong code does not unlock"

    post candidate_status_unlock_offer_path(token), params: { code: }
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Accept" }
    assert_equal "accepted", offer.reload.response
  end

  # D41: one form instance is throttled at its own limit; another form from the SAME address (a
  # carrier IP shared by many candidates) is still served; the per-IP guard still exists, looser.
  test "one form instance is throttled; another candidate on the same IP is not; the per-IP guard holds (D41)" do
    open_portal(@job)
    limits = Glassbox::Settings::RATE_LIMITS
    form_a = lamar_form_token
    bad = { knockout: answers_for(@job), lamaran: application_params(@job, phone: "12", consent_token: form_a).except(:knockout) }
    statuses = (limits[:lamar_per_form][:to] + 1).times.map { post(lamar_path(@job.public_code), params: bad) && response.status }
    assert_equal [422] * limits[:lamar_per_form][:to] + [429], statuses
    form_b = lamar_form_token
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job), lamaran: application_params(@job, consent_token: form_b).except(:knockout) }
    assert_response :success, "a second candidate behind the same IP is served"
    Rails.cache.clear
    per_ip = (limits[:lamar_per_ip][:to] + 1).times.map { post(lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }) && response.status }
    assert_equal 429, per_ip.last
    assert_equal 1, per_ip.count(429), "the per-IP guard trips only after #{limits[:lamar_per_ip][:to]} requests"
  end
end
