require "test_helper"
require_relative "portal_engine_support"

# Hunt items 5 and 6 (brief 02): the offer (E24, D33, D36 code) and the objection (E21), through
# real requests where the candidate acts, and through the services where staff act. The billing
# hook is counted on every path that could fire it twice.
class EnginePortalOfferAndObjectionTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @job = portal_job
    open_portal(@job)
  end

  def ready_with_offer!
    application, token = offer_ready!(@job)
    close_s1_and_pass_s5!(@job, [application])
    [application, token, upload_offer!(application)]
  end

  def unlock!(token, email = "rina@uji.example")
    post candidate_status_offer_code_path(token)
    code = last_code_for(email)
    post candidate_status_unlock_offer_path(token), params: { code: }
    code
  end

  def hook_count
    count = 0
    callback = ->(*) { count += 1 }
    ActiveSupport::Notifications.subscribed(callback, "offer_accepted.glassbox") { yield }
    count
  end

  test "no answer without the code: accept and decline over HTTP store nothing and fire no hook" do
    _application, token, offer = ready_with_offer!
    fired = hook_count do
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Terima" }
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "declined", reason: "x", commit: "Tolak" }
    end
    assert_equal [nil, 0], [offer.reload.response, fired]
  end

  test "a code works once: reusing it in a fresh browser does not unlock" do
    _application, token, offer = ready_with_offer!
    code = unlock!(token)
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :success, "control: the first use unlocks"
    reset!
    post candidate_status_unlock_offer_path(token), params: { code: }
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :redirect, "the same code unlocked a second browser"
  end

  # travel_to drops microseconds, so the boundary is tested with explicit instants.
  test "a code expires at exactly 15 minutes: one second before unlocks, at the expiry it does not" do
    application, token, offer = ready_with_offer!
    record, code = OfferAccessCode.issue!(application)
    refute OfferAccessCode.redeem(application, code, now: record.expires_at), "redeemed AT the expiry instant"
    assert OfferAccessCode.redeem(application, code, now: record.expires_at - 1.second), "control: one second before"
    _record, code2 = OfferAccessCode.issue!(application)
    travel 15.minutes + 1.second do
      post candidate_status_unlock_offer_path(token), params: { code: code2 }
      get candidate_status_offer_pdf_path(token, offer.id)
      assert_response :redirect, "an expired code unlocked the offer"
    end
  end

  test "the unlock lasts 15 minutes in the browser; after that the answer needs a new code" do
    _application, token, offer = ready_with_offer!
    unlock!(token)
    travel 16.minutes do
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Terima" }
      assert_nil offer.reload.response
    end
  end

  test "two answers over HTTP: the first wins, the second is refused, the hook fires once" do
    _application, token, offer = ready_with_offer!
    unlock!(token)
    fired = hook_count do
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Terima" }
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Terima" }
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "declined", reason: "Berubah pikiran", commit: "Tolak" }
    end
    assert_equal ["accepted", 1], [offer.reload.response, fired]
  end

  test "a decline without a reason over HTTP is refused and stores nothing" do
    _application, token, offer = ready_with_offer!
    unlock!(token)
    post candidate_status_respond_offer_path(token, offer.id), params: { response: "declined", reason: "   ", commit: "Tolak" }
    assert_nil offer.reload.response
    refused_by_database { OfferDocument.where(id: offer.id).update_all(response: "declined", response_reason: "  ") }
  end

  test "an unknown response value is refused" do
    _application, token, offer = ready_with_offer!
    unlock!(token)
    post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted'; --", commit: "Terima" }
    assert_nil offer.reload.response
  end

  test "acceptance on an old version over HTTP is refused after a new version is uploaded" do
    application, token, old = ready_with_offer!
    unlock!(token)
    upload_offer!(application)
    post candidate_status_respond_offer_path(token, old.id), params: { response: "accepted", commit: "Terima" }
    assert_nil old.reload.response
  end

  test "after a decline a new version may be uploaded and accepted; after an acceptance no version may be uploaded" do
    application, token, first = ready_with_offer!
    unlock!(token)
    fired = hook_count do
      post candidate_status_respond_offer_path(token, first.id), params: { response: "declined", reason: "Gaji", commit: "Tolak" }
    end
    assert_equal ["declined", 0], [first.reload.response, fired], "the billing hook fired on a decline"
    second = upload_offer!(application)
    post candidate_status_respond_offer_path(token, second.id), params: { response: "accepted", commit: "Terima" }
    assert_equal "accepted", second.reload.response
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(application) }
    assert_equal 2, application.offer_documents.count
  end

  test "an offer answered the day after its valid_until date is refused" do
    application, token, = ready_with_offer!
    offer = upload_offer!(application, valid_until: 3.days.from_now.to_date)
    unlock!(token)
    travel_to (offer.valid_until + 1).in_time_zone.beginning_of_day + 1.minute do
      unlock!(token)
      post candidate_status_respond_offer_path(token, offer.id), params: { response: "accepted", commit: "Accept" }
      assert_nil offer.reload.response, "answered after 'Reply by'"
    end
  end

  test "an offer upload is refused before the last stage passed: last stage open, or eliminated, or not reached" do
    application, = offer_ready!(@job)
    other, = submit!(@job, email: "lain@uji.example")
    decide_stage!(other, "S1", outcome: "pass", close: false)
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(application) } # S5 not reached
    Stages::Close.call(stage: stage_of(@job, "S1"))
    decide_stage!(application, "S5", outcome: "pass", close: false)
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(application) } # S5 still open
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(other) }
  end

  test "an offer upload is refused after an elimination at the last stage" do
    application, = offer_ready!(@job)
    Stages::Close.call(stage: stage_of(@job, "S1"))
    decide_stage!(application, "S5", outcome: "eliminate", score: 20)
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(application) }
  end

  # D36 / Pasal 40: withdrawal ends the application and stops processing. Uploading an offer
  # (salary, start date) to a person who withdrew is processing their data after withdrawal.
  test "F8 fixed: an offer cannot be uploaded to an application whose consent was withdrawn" do
    application, = offer_ready!(@job)
    close_s1_and_pass_s5!(@job, [application])
    Portal::CandidateActions.new(application).withdraw_consent!
    assert_raises(Portal::UploadOffer::Refused) { upload_offer!(application) }
  end

  # D36 threat model: a forwarded link must not reach the salary. Before the F9/F10 fixes every
  # "Kirim kode" press added another live 6-digit code and only unlock was rate-limited, so N
  # presses multiplied the odds of a guess by N and sent the candidate N emails.
  test "F9 fixed: sending the offer code is rate-limited like unlocking it" do
    _application, token, = ready_with_offer!
    12.times do
      post candidate_status_offer_code_path(token)
    end
    assert_operator MailDelivery.where(kind: "offer_code").count, :<=, 5, "#{MailDelivery.where(kind: 'offer_code').count} code emails from one link in one minute"
  end

  test "F10 fixed: a newly issued offer code retires the earlier unused ones (at most one live code)" do
    application, = ready_with_offer!
    _r1, first = OfferAccessCode.issue!(application)
    _r2, _second = OfferAccessCode.issue!(application)
    refute OfferAccessCode.redeem(application, first), "an older code still unlocks after a newer one was sent"
  end

  test "unlocking is rate-limited: after 5 wrong codes even the right code is refused for a while" do
    _application, token, offer = ready_with_offer!
    post candidate_status_offer_code_path(token)
    code = last_code_for("rina@uji.example")
    wrong = code == "000000" ? "111111" : "000000"
    5.times { post candidate_status_unlock_offer_path(token), params: { code: wrong } }
    post candidate_status_unlock_offer_path(token), params: { code: }
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :redirect, "a sixth attempt inside ten minutes was accepted"
  end

  # Rails' rate_limit keys on controller + name + `by`. Two unnamed limits in one controller share
  # ONE counter (actionpack rate_limiting.rb:75); before the G2 fix sending codes used up unlock
  # attempts. The limits are now named "offer-code-send" and "offer-code-unlock".
  test "G2 fixed: sending codes does not use up the unlock attempts (separate counters)" do
    _application, token, offer = ready_with_offer!
    2.times { post candidate_status_offer_code_path(token) }
    code = last_code_for("rina@uji.example")
    wrong = code == "000000" ? "111111" : "000000"
    3.times { post candidate_status_unlock_offer_path(token), params: { code: wrong } }
    post candidate_status_unlock_offer_path(token), params: { code: } # 4th unlock attempt, limit is 5
    get candidate_status_offer_pdf_path(token, offer.id)
    assert_response :success, "the right code on the 4th unlock attempt was refused: the two code requests counted against it"
  end

  # Before the G3 fix the limit was keyed on the IP. Candidates on Indonesian mobile data commonly
  # share a carrier NAT address, so one candidate's three requests locked out every other
  # candidate on that IP. It is now keyed on the status link's digest.
  test "G3 fixed: one candidate's code requests do not block another candidate's (limit per link, not per IP)" do
    application, token = submit!(@job)
    other, other_token = submit!(@job, name: "Budi Santoso", email: "budi@uji.example", phone: "081298765432")
    [application, other].each { |app| decide_stage!(app, "S1", outcome: "pass", close: false) }
    close_s1_and_pass_s5!(@job, [application])
    upload_offer!(application)
    3.times { post candidate_status_offer_code_path(token) }
    post candidate_status_offer_code_path(other_token)
    assert_equal 1, MailDelivery.where(job_application: other, kind: "offer_code").count,
                 "another candidate on the same IP could not get a code"
  end

  test "codes are stored only as digests" do
    application, = ready_with_offer!
    record, code = OfferAccessCode.issue!(application)
    refute_includes OfferAccessCode.where(id: record.id).pluck(:code_digest).join, code
    refute_equal code, record.code_digest
  end

  # --- objection (E21) ----------------------------------------------------------------------

  test "objection refused on a non-S1 stage, an open stage, a pass, and twice while open; allowed on a closed S1 elimination" do
    application, token = submit!(@job)
    passer, passer_token = submit!(@job, email: "lolos@uji.example")
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    p1 = decide_stage!(application, "S1", outcome: "eliminate", score: 30, close: false)
    p_pass = decide_stage!(passer, "S1", outcome: "pass", close: false)
    post candidate_status_object_path(token, p1.id), params: { text: "Keliru", commit: "Kirim keberatan" }
    assert_equal 0, Objection.count, "objection on an OPEN stage"

    Stages::Close.call(stage: s1.reload)
    post candidate_status_object_path(token, p1.id), params: { text: "   ", commit: "Kirim keberatan" }
    assert_equal 0, Objection.count, "an empty objection"
    post candidate_status_object_path(token, p1.id), params: { text: "Keliru", commit: "Kirim keberatan" }
    assert_equal 1, Objection.count, "control: a closed S1 elimination accepts an objection"
    post candidate_status_object_path(token, p1.id), params: { text: "Lagi", commit: "Kirim keberatan" }
    assert_equal 1, Objection.count, "a second objection while one is open"
    refused_by_database { Objection.create!(participation: p1, text: "raw", received_at: Time.current) }

    post candidate_status_object_path(passer_token, p_pass.id), params: { text: "x" }
    assert_equal 1, Objection.count, "objection on a closed S1 PASS"
  end

  test "objection refused on a closed S5 elimination (not S1)" do
    application, token = offer_ready!(@job)
    Stages::Close.call(stage: stage_of(@job, "S1"))
    p5 = decide_stage!(application, "S5", outcome: "eliminate", score: 20)
    post candidate_status_object_path(token, p5.id), params: { text: "Keliru", commit: "Kirim keberatan" }
    assert_equal 0, Objection.count
  end

  test "objection refused on a closed S1 pass" do
    application, token = offer_ready!(@job)
    p1 = application.participations.find_by!(stage: stage_of(@job, "S1"))
    Stages::Close.call(stage: stage_of(@job, "S1"))
    post candidate_status_object_path(token, p1.id), params: { text: "Keliru", commit: "Kirim keberatan" }
    assert_equal 0, Objection.count
  end

  test "an answered objection cannot be answered again, and a second objection is then allowed once" do
    application, token = submit!(@job)
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    p1 = decide_stage!(application, "S1", outcome: "eliminate", score: 30, close: false)
    Stages::Close.call(stage: s1.reload)
    objection = Portal::CandidateActions.new(application).object!(p1.id, "Keliru")
    sign_in_as staff_user("reviewer")
    post staff_objection_answer_path(objection), params: { outcome: "not_upheld", answer: "Sudah ditinjau", commit: "Kirim jawaban" }
    first_answer = objection.reload.answered_at
    assert first_answer
    post staff_objection_answer_path(objection), params: { outcome: "upheld", answer: "Ganti", commit: "Kirim jawaban" }
    assert_equal ["not_upheld", first_answer.to_i], [objection.reload.outcome, objection.answered_at.to_i]
    get candidate_status_path(token)
    assert_includes response.body, "Sudah ditinjau", "the answer is shown on the status page"
  end
end
