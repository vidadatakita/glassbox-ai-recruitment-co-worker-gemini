require "test_helper"

# Candidate actions from the status link (BP §3.6 B3–B6; D33, D36, E21, E24).
class Portal::CandidateActionsTest < ActiveSupport::TestCase
  setup do
    @job = portal_job
    open_portal(@job)
    @application, @token = submit!(@job)
    @actions = Portal::CandidateActions.new(@application)
  end

  def pass_last_stage!
    s1 = @job.stages.find_by!(code: "S1")
    s5 = @job.stages.find_by!(code: "S5")
    Stages::Open.call(stage: s1)
    p1 = @application.participations.find_by!(stage: s1)
    p1.update!(attendance: "attended")
    add_score(p1, 80)
    decide!(p1, outcome: "pass")
    Stages::Close.call(stage: s1)
    Stages::Open.call(stage: s5)
    p5 = enter_stage_by_choice!(@application, s5, attendance: "attended")
    add_score(p5, 85)
    decide!(p5, outcome: "pass")
    Stages::Close.call(stage: s5)
  end

  def upload_offer!
    Portal::UploadOffer.call(application: @application, actor: staff_user("consultant"),
                             params: { pdf: pdf_upload, start_at: "2026-11-17 08:00", valid_until: 30.days.from_now.to_date.iso8601,
                                       day_one_notes: "Bawa KTP asli." })
  end

  test "an offer cannot be uploaded before the last stage is closed with a pass" do
    assert_raises(Portal::UploadOffer::Refused) { upload_offer! }
  end

  test "an offer is accepted at most once; a second answer is refused" do
    pass_last_stage!
    offer = upload_offer!
    events = []
    ActiveSupport::Notifications.subscribed(->(*args) { events << args }, "offer_accepted.glassbox") do
      @actions.respond_to_offer!(offer.id, response: "accepted")
    end
    assert_equal 1, events.size, "the billing hook fires exactly once"
    error = assert_raises(Portal::CandidateActions::Refused) { @actions.respond_to_offer!(offer.id, response: "declined", reason: "x") }
    assert_match(/already answered this offer/, error.message)
    assert_equal "accepted", offer.reload.response
  end

  test "the database refuses a second accepted offer across versions" do
    pass_last_stage!
    first = upload_offer!
    second = upload_offer!
    @actions.respond_to_offer!(second.id, response: "accepted")
    error = refused_by_database { OfferDocument.where(id: first.id).update_all(response: "accepted") }
    assert_match(/offer_documents_one_acceptance/, error.message)
  end

  test "a newer version voids the older one's answer" do
    pass_last_stage!
    old = upload_offer!
    upload_offer!
    error = assert_raises(Portal::CandidateActions::Refused) { @actions.respond_to_offer!(old.id, response: "accepted") }
    assert_match(/replaced by a newer version/, error.message)
  end

  test "a decline needs a reason" do
    pass_last_stage!
    offer = upload_offer!
    assert_raises(Portal::CandidateActions::Refused) { @actions.respond_to_offer!(offer.id, response: "declined", reason: " ") }
  end

  test "an objection is accepted only on a closed S1 elimination, once while open" do
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    p1 = @application.participations.find_by!(stage: s1)
    p1.update!(attendance: "attended")
    add_score(p1, 40)
    decide!(p1, outcome: "eliminate", reason_code: "below_threshold")
    assert_raises(Portal::CandidateActions::Refused) { @actions.object!(p1.id, "Saya punya pengalaman") }
    Stages::Close.call(stage: s1)
    @actions.object!(p1.id, "Saya punya pengalaman")
    error = assert_raises(Portal::CandidateActions::Refused) { @actions.object!(p1.id, "lagi") }
    assert_match(/being reviewed/, error.message)
  end

  test "a withdrawal is decided by rule on the open stage, so the stage can still close (F3)" do
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    @actions.withdraw_consent!
    decision = @application.participations.find_by!(stage: s1).current_decision
    assert_equal %w[eliminate rule withdrew], [decision.outcome, decision.basis, decision.reason_code]
    assert_equal "closed", Stages::Close.call(stage: s1).status
  end

  test "a withdrawal before S1 opens is decided when S1 opens (F3 with D37)" do
    @actions.withdraw_consent!
    s1 = @job.stages.find_by!(code: "S1")
    Stages::Open.call(stage: s1)
    assert_equal "withdrew", @application.participations.find_by!(stage: s1).current_decision.reason_code
  end

  test "no offer is uploaded after a withdrawal (F8, Pasal 40)" do
    pass_last_stage!
    @actions.withdraw_consent!
    assert_raises(Portal::UploadOffer::Refused) { upload_offer! }
  end

  test "a failed re-issue keeps the old link working and records the failure (F1)" do
    failing = Class.new { def self.status_link(*) = raise(SocketError, "getaddrinfo: Name or service not known") }
    Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example", mailer: failing)
    assert OneTimeLink.live("candidate_status", @token), "the old link must survive a failed send"
    assert_equal ["failed", "SocketError"], MailDelivery.last.values_at(:status, :error_class)
    assert_equal 1, OneTimeLink.where(subject: @application, revoked_at: nil).count
  end

  test "withdrawing consent kills every status link at once (D36, Pasal 40)" do
    @actions.withdraw_consent!
    assert_nil OneTimeLink.live("candidate_status", @token)
    assert_equal "withdrawn", @application.reload.status
  end

  test "re-issue revokes the old link and mails a new one to the address on file" do
    assert_equal :sent, Portal::ReissueLink.call(job_code: @job.public_code, email: "RINA@uji.example ")
    assert_nil OneTimeLink.live("candidate_status", @token), "the old link is revoked"
    assert_equal 1, OneTimeLink.where(subject: @application, revoked_at: nil).count
    mail = ActionMailer::Base.deliveries.last
    assert_equal ["rina@uji.example"], mail.to
    assert_equal "sent", MailDelivery.last.status
  end

  test "re-issue with an unknown email queues a request and sends nothing" do
    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_equal :queued, Portal::ReissueLink.call(job_code: @job.public_code, email: "orang.lain@uji.example")
    end
    assert OneTimeLink.live("candidate_status", @token), "an unknown email never revokes someone's link"
    assert_equal 1, LinkRequest.count
  end

  test "an appointment of another application cannot be confirmed with this link" do
    other, = submit!(@job, email: "lain@uji.example")
    s5 = @job.stages.find_by!(code: "S5")
    p_other = enter_stage_by_choice!(other, s5)
    appointment = p_other.create_appointment!(starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, mode: "onsite",
                                              place_or_link: "Lobi", contact: "Dewi")
    assert_raises(Portal::CandidateActions::Refused) { @actions.confirm_appointment!(appointment.id) }
    assert_equal "pending", appointment.reload.confirmation
  end
end
