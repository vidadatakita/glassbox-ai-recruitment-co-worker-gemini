require "test_helper"
require_relative "portal_engine_support"

# Run 3 of the feature-02 test engine (2026-10-10). Two questions from the coordinator:
#
# 1. The D41 rate limits: can a script dodge the per-form limit by omitting or rotating the
#    consent token, and is anything keyed so that real candidates still block each other?
#    Answer as measured below: the per-form key binds only a script that REUSES one token; a
#    script that rotates tokens is bounded by the per-IP limit (120 requests / 60 s on step 1 +
#    step 2, so at most 60 stored applications per minute per IP). Real candidates on one IP do
#    not share a per-form or per-link bucket; they share only the per-IP buckets.
#
# 2. The Portal Pelamar box must never offer an action the server refuses. Every state the
#    window can be in is rendered for hr_pic and consultant, every offered button is PRESSED as a
#    browser would, and the server must accept it.
class EnginePortalRateLimitsAndBoxTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  LIMITS = Glassbox::Settings::RATE_LIMITS

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @job = portal_job
    open_portal(@job)
  end

  def ip(n) = { "REMOTE_ADDR" => "10.20.30.#{n}" }

  def submit_with(token, email:, env: ip(1), overrides: {})
    lamaran = application_params(@job, { email: }.merge(overrides)).except(:knockout)
    lamaran[:consent_token] = token if token
    post lamar_path(@job.public_code), params: { knockout: answers_for(@job), lamaran:, commit: "Kirim Lamaran" }, env:
  end

  def fresh_token(env: ip(1))
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }, env: env
    Nokogiri::HTML(response.body).at_css("input[name='lamaran[consent_token]']")&.[]("value")
  end

  def stored = JobApplication.where.not(candidate_id: nil).count

  # --- D41: per-form limit -------------------------------------------------------------------

  test "D41: one form instance (one token) is refused after #{LIMITS[:lamar_per_form][:to]} submits in #{LIMITS[:lamar_per_form][:within]} s" do
    freeze_time
    token = fresh_token
    statuses = (LIMITS[:lamar_per_form][:to] + 1).times.map do |i|
      submit_with(token, email: "x#{i}@uji.example", overrides: { phone: "123" }) # invalid: 422, nothing stored
      response.status
    end
    assert_equal [422] * LIMITS[:lamar_per_form][:to] + [429], statuses
  end

  test "D41: omitting the token puts the request in a per-IP 'no-form' bucket that never blocks a real form on that IP" do
    freeze_time
    (LIMITS[:lamar_per_form][:to] + 2).times { |i| submit_with(nil, email: "bot#{i}@uji.example") }
    assert_response :too_many_requests, "control: token-less posts are limited"
    assert_equal 0, stored, "a token-less post stored an application"
    submit_with(fresh_token, email: "rina@uji.example")
    assert_response :success, "a real candidate on the same IP was blocked by token-less traffic"
    assert_equal 1, stored
  end

  test "D41: forged tokens (each a new bucket) store nothing and are still bounded by the per-IP limit" do
    freeze_time
    codes = (1..LIMITS[:lamar_per_ip][:to] + 1).map do |i|
      submit_with("forged-#{i}", email: "f#{i}@uji.example", env: ip(9))
      response.status
    end
    assert_equal 0, stored
    assert_equal 429, codes.last, "the per-IP limit did not stop a forged-token flood"
    assert_equal [422], codes.first(LIMITS[:lamar_per_ip][:to]).uniq
  end

  # The measured dodge: rotating the token (one step-1 POST per submit) escapes the per-form
  # limit entirely; the only bound is the per-IP limit on step 1 + step 2 together.
  # Not under freeze_time: the token is a signed {template, days, expiry} message, so two renders
  # in the same instant are byte-identical; real clocks move between requests.
  test "D41: a token-rotating script is bounded only by the per-IP limit: at most half of #{LIMITS[:lamar_per_ip][:to]} applications per window" do
    i = 0
    cap = LIMITS[:lamar_per_ip][:to] # bounded: without a working limit the loop ends here and fails
    while i < cap
      token = fresh_token(env: ip(7))
      break if response.status == 429

      submit_with(token, email: "s#{i}@uji.example", env: ip(7))
      break if response.status == 429

      i += 1
    end
    assert_equal LIMITS[:lamar_per_ip][:to] / 2, stored, "applications stored from one IP inside one window"
    submit_with(fresh_token(env: ip(8)), email: "rina@uji.example", env: ip(8))
    assert_response :success, "a candidate on another IP was blocked"
  end

  test "D41: two real candidates on ONE IP do not share a per-form bucket" do
    a = fresh_token
    b = fresh_token
    refute_equal a, b, "two step-2 renders produced the same token (a shared per-form bucket)"
    LIMITS[:lamar_per_form][:to].times { |i| submit_with(a, email: "a#{i}@uji.example", overrides: { phone: "1" }) }
    submit_with(b, email: "budi@uji.example")
    assert_response :success
  end

  test "D41: the per-IP limit counts step 1 and step 2 together, and lifts after the window" do
    freeze_time
    LIMITS[:lamar_per_ip][:to].times { post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }, env: ip(3) }
    assert_response :success, "control: the #{LIMITS[:lamar_per_ip][:to]}th request passes"
    submit_with("x", email: "z@uji.example", env: ip(3))
    assert_response :too_many_requests
    travel LIMITS[:lamar_per_ip][:within].seconds + 1.second
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }, env: ip(3)
    assert_response :success
  end

  test "D41: Minta link baru is limited per IP and the limit does not reach another IP" do
    freeze_time
    (LIMITS[:link_request_per_ip][:to] + 1).times { post link_requests_path, params: { job_code: "x", email: "a@uji.example" }, env: ip(4) }
    assert_response :too_many_requests
    assert_equal LIMITS[:link_request_per_ip][:to], LinkRequest.count, "requests past the limit were stored"
    post link_requests_path, params: { job_code: "x", email: "b@uji.example" }, env: ip(5)
    assert_response :success
  end

  # --- offer-code limits are per link, across IPs ----------------------------------------------

  test "G2/G3: a forwarded link gets only #{5} unlock attempts per 10 minutes even when every guess comes from a new IP" do
    application, token = submit!(@job)
    decide_stage!(application, "S1", outcome: "pass", close: false)
    close_s1_and_pass_s5!(@job, [application])
    offer = upload_offer!(application)
    post candidate_status_offer_code_path(token), env: ip(1)
    code = last_code_for("rina@uji.example")
    wrong = code == "000000" ? "111111" : "000000"
    5.times { |i| post candidate_status_unlock_offer_path(token), params: { code: wrong }, env: ip(100 + i) }
    post candidate_status_unlock_offer_path(token), params: { code: }, env: ip(200)
    get candidate_status_offer_pdf_path(token, offer.id), env: ip(200)
    assert_response :redirect, "a sixth guess from a new IP was accepted"
  end

  test "G3: three code requests on one link do not stop another link on another IP, and the 4th on the same link is refused" do
    a, a_token = submit!(@job)
    b, b_token = submit!(@job, name: "Budi", email: "budi@uji.example", phone: "081298765432")
    4.times { post candidate_status_offer_code_path(a_token), env: ip(1) }
    post candidate_status_offer_code_path(b_token), env: ip(2)
    assert_equal [3, 1], [MailDelivery.where(job_application: a).count, MailDelivery.where(job_application: b).count]
  end

  # --- the Portal Pelamar box never offers what the server refuses ----------------------------

  def box_buttons
    Nokogiri::HTML(response.body).css(".hris-form-card form button[name=commit]").map { |b| b["value"] }
  end

  def press_box(role, label, fill = {})
    sign_in_as staff_user(role)
    get staff_job_path(@job)
    events = @job.application_window_events.count
    press(label, fill)
    follow_redirect!
    assert_equal events + 1, @job.application_window_events.count, "#{role}: '#{label}' changed nothing"
  end

  test "box: open portal offers Close portal and the server accepts it, for hr_pic and consultant" do
    %w[hr_pic consultant].each do |role|
      Portal::WindowChange.reopen!(job: @job, actor: staff_user("hr_pic"), reason: "lagi") unless ApplicationWindow.new(@job).open?
      press_box(role, "Close portal")
      assert_equal :closed_by_hr, ApplicationWindow.new(@job).state
    end
  end

  test "box: closed by HR, by date and by quota offer Reopen, and the server accepts it with only a reason" do
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    press_box("hr_pic", "Reopen", "reason" => "Dibuka kembali")
    assert ApplicationWindow.new(@job).open?

    job = portal_job
    @job = job
    open_portal(job, closes_at: 1.hour.from_now)
    travel 2.hours do
      assert_equal :closed_by_date, ApplicationWindow.new(job).state
      press_box("consultant", "Reopen", "reason" => "Perpanjang")
      assert ApplicationWindow.new(job).open?
    end
  end

  # The box offers "Reopen" on a portal closed by its quota, with a quota field. A quota at or
  # below the applications already received reopens a portal that is closed again at once, and
  # the screen says "Applicant portal reopened." (the G4 class: success reported, nobody admitted).
  test "FINDING: reopening a portal closed by quota with a quota not above the count is refused, not reported as reopened" do
    job = portal_job
    @job = job
    open_portal(job, quota: 1)
    submit!(job)
    assert_equal :closed_by_quota, ApplicationWindow.new(job).state
    sign_in_as staff_user("hr_pic")
    get staff_job_path(job)
    assert_includes box_buttons, "Reopen"
    press("Reopen", "reason" => "Tambah", "quota" => "1")
    follow_redirect!
    refute (response.body.include?("Applicant portal reopened.") && !ApplicationWindow.new(job).open?),
           "the screen says 'dibuka lagi' while the window is #{ApplicationWindow.new(job).state}"
  end

  test "box: closed by stage and blocked by settings offer no open/reopen button, and say why" do
    application, = submit!(@job)
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(application, "S1", outcome: "pass", close: false)
    Stages::Close.call(stage: s1.reload)
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      assert_empty box_buttons & ["Open portal", "Reopen", "Close portal"], "#{role}: an action offered on a stage-closed portal"
      assert_includes response.body, "CV screening is closed"
    end

    fresh = portal_job
    ConsentTemplate.create!(ConsentTemplate::DRAFT.merge(version: "draft-later", effective_from: 1.minute.from_now, created_at: Time.current))
    travel 2.minutes do
      %w[hr_pic consultant].each do |role|
        sign_in_as staff_user(role)
        get staff_job_path(fresh)
        assert_empty box_buttons & ["Open portal", "Reopen"], "#{role}: open offered while the consent has placeholders"
        assert_includes response.body, "PLACEHOLDER"
      end
    end
  end

  # Three-role model (17 Oct 2026): owner and reviewer are both HR managers, who get no window button;
  # superadmin passes every role check, so it is offered Open portal (asserted as the allowed side).
  test "box: a never-opened ready job offers Open portal and the server accepts it; HR managers see no window button" do
    @job = portal_job
    %w[owner reviewer].each do |role|
      sign_in_as staff_user(role)
      get staff_job_path(@job)
      assert_empty box_buttons & ["Open portal", "Reopen", "Close portal"], "#{role} is offered a window action"
    end
    sign_in_as staff_user("superadmin")
    get staff_job_path(@job)
    assert_includes box_buttons, "Open portal", "superadmin passes every role check"
    press_box("consultant", "Open portal")
    assert ApplicationWindow.new(@job).open?
  end

  test "box: a written but unapproved ad offers Open portal directly, and opening approves the ad" do
    @job = portal_job
    @job.update_columns(ad_approved_at: nil, ad_approved_by_id: nil, ad_text: "Tentang posisi ini\nIklan uji.")
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@job)
    refute_includes box_buttons, "Approve job ad"
    press("Open portal")
    assert ApplicationWindow.new(@job).open?
    assert @job.reload.ad_approved_at
  end
end
