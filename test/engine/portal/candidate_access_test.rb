require "test_helper"
require_relative "portal_engine_support"

# Hunt item 1 and 4 (brief 02): personal data reaching the wrong person through a candidate URL,
# and the status-link controls of D36. Every candidate action is tried with ANOTHER
# application's ids through a valid link; every action is tried with a revoked and a withdrawn
# link. Controls: the same request with the candidate's OWN id succeeds, so each refusal is a
# refusal of the scoping, not of the request.
class EnginePortalCandidateAccessTest < ActionDispatch::IntegrationTest
  include PortalEngineSupport

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @job = portal_job
    open_portal(@job)
    @rina, @rina_token = submit!(@job)
    @budi, @budi_token = submit!(@job, name: "Budi Santoso", email: "budi@uji.example", phone: "081298765432")
  end

  def appointment_for(application, code: "S1")
    stage = stage_of(@job, code)
    participation = application.participations.find_by(stage:) || Participation.create!(job_application: application, stage:)
    participation.create_appointment!(starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour, mode: "onsite",
                                      place_or_link: "Lobi Gedung A", contact: "Dewi 0812", confirmation: "pending")
  end

  test "IDOR: confirm and reschedule another application's appointment are refused; own succeeds (control)" do
    budi_appt = appointment_for(@budi)
    post candidate_status_confirm_path(@rina_token, budi_appt.id), params: { commit: "Konfirmasi hadir" }
    post candidate_status_reschedule_path(@rina_token, budi_appt.id), params: { reason: "Bentrok", commit: "Kirim permintaan" }
    assert_equal ["pending", nil], [budi_appt.reload.confirmation, budi_appt.reschedule_reason]

    own = appointment_for(@rina)
    post candidate_status_confirm_path(@rina_token, own.id), params: { commit: "Konfirmasi hadir" }
    assert_equal "confirmed", own.reload.confirmation, "control: the own appointment is confirmed"
  end

  test "IDOR: an objection on another application's participation is refused; own succeeds (control)" do
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    [@rina, @budi].each { |app| decide_stage!(app, "S1", outcome: "eliminate", score: 30, close: false) }
    Stages::Close.call(stage: s1.reload)
    budi_p = @budi.participations.find_by!(stage: s1)
    rina_p = @rina.participations.find_by!(stage: s1)

    post candidate_status_object_path(@rina_token, budi_p.id), params: { text: "Bukan saya", commit: "Kirim keberatan" }
    assert_equal 0, Objection.count, "an objection was filed on another candidate's result"
    post candidate_status_object_path(@rina_token, rina_p.id), params: { text: "Saya memenuhi syarat", commit: "Kirim keberatan" }
    assert_equal [rina_p.id], Objection.pluck(:participation_id), "control: the own objection is filed"
  end

  test "IDOR: another application's offer cannot be answered or downloaded, even with an unlocked session" do
    [@rina, @budi].each { |app| decide_stage!(app, "S1", outcome: "pass", close: false) }
    close_s1_and_pass_s5!(@job, [@rina, @budi])
    budi_offer = upload_offer!(@budi)
    rina_offer = upload_offer!(@rina)

    post candidate_status_offer_code_path(@rina_token)
    post candidate_status_unlock_offer_path(@rina_token), params: { code: last_code_for("rina@uji.example") }
    get candidate_status_offer_pdf_path(@rina_token, rina_offer.id)
    assert_response :success, "control: the own offer opens after the code"

    get candidate_status_offer_pdf_path(@rina_token, budi_offer.id)
    refute_equal "application/pdf", response.media_type, "another candidate's offer PDF was served"
    post candidate_status_respond_offer_path(@rina_token, budi_offer.id), params: { response: "declined", reason: "x" }
    assert_nil budi_offer.reload.response, "another candidate's offer was answered"

    # The unlocked session belongs to Rina's application only; Budi's link in the same browser stays locked.
    get candidate_status_offer_pdf_path(@budi_token, budi_offer.id)
    assert_response :redirect
  end

  test "another application's offer code does not unlock this application's offer" do
    [@rina, @budi].each { |app| decide_stage!(app, "S1", outcome: "pass", close: false) }
    close_s1_and_pass_s5!(@job, [@rina, @budi])
    rina_offer = upload_offer!(@rina)
    upload_offer!(@budi)
    post candidate_status_offer_code_path(@budi_token)
    budi_code = last_code_for("budi@uji.example")
    post candidate_status_unlock_offer_path(@rina_token), params: { code: budi_code }
    get candidate_status_offer_pdf_path(@rina_token, rina_offer.id)
    assert_response :redirect, "Budi's code unlocked Rina's offer"
  end

  test "the status page never shows another candidate, a score, the threshold or a CV link" do
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(@rina, "S1", outcome: "pass", score: 81.7, close: false)
    decide_stage!(@budi, "S1", outcome: "pass", score: 93.3, close: false)
    Stages::Close.call(stage: s1.reload)
    get candidate_status_path(@rina_token)
    assert_response :success
    text = Nokogiri::HTML(response.body).text
    ["Budi", "budi@uji.example", "081298765432", "rina@uji.example", "081234567890"].each do |leak|
      refute_includes response.body, leak, "#{leak} on the status page"
    end
    refute_match(/\b81[.,]7\b|\b93[.,]3\b|\b60([.,]0)?\b|\b70([.,]0)?\b/, text, "a score or a threshold in the page text")
    refute_match(%r{/staff/|rails/active_storage|cv-}, response.body, "a CV or staff link on the status page")
  end

  # Builder default (feature record §8): an outcome appears only once the stage is CLOSED, so a
  # provisional "belum lolos" that a person may still reverse never reaches the candidate.
  test "a decision on a still-open stage is not shown; the same decision shows once the stage closes (control)" do
    s1 = stage_of(@job, "S1")
    Stages::Open.call(stage: s1)
    decide_stage!(@rina, "S1", outcome: "eliminate", score: 20, close: false)
    decide_stage!(@budi, "S1", outcome: "pass", close: false)
    get candidate_status_path(@rina_token)
    refute_includes response.body, "not passed"
    refute_includes response.body, "Raise an objection"
    Stages::Close.call(stage: s1.reload)
    get candidate_status_path(@rina_token)
    assert_includes response.body, "CV screening: not passed", "control"
  end

  test "a revoked link (after re-issue) acts on nothing: every candidate POST and GET is refused" do
    appointment = appointment_for(@rina)
    Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example")
    get candidate_status_path(@rina_token)
    assert_response :not_found
    post candidate_status_confirm_path(@rina_token, appointment.id)
    assert_response :not_found
    post candidate_status_reschedule_path(@rina_token, appointment.id), params: { reason: "x" }
    assert_response :not_found
    post candidate_status_withdraw_path(@rina_token)
    assert_response :not_found
    post candidate_status_offer_code_path(@rina_token)
    assert_response :not_found
    assert_equal "pending", appointment.reload.confirmation
    assert_nil @rina.reload.consent_withdrawn_at, "a revoked link withdrew the application"
    assert_equal 0, OfferAccessCode.count
  end

  test "a withdrawn application's link refuses every action, including the offer code and a second withdrawal" do
    appointment = appointment_for(@rina)
    post candidate_status_withdraw_path(@rina_token), params: { commit: "Tarik persetujuan" }
    withdrawn_at = @rina.reload.consent_withdrawn_at
    assert withdrawn_at
    [
      -> { post candidate_status_confirm_path(@rina_token, appointment.id) },
      -> { post candidate_status_reschedule_path(@rina_token, appointment.id), params: { reason: "x" } },
      -> { post candidate_status_offer_code_path(@rina_token) },
      -> { post candidate_status_unlock_offer_path(@rina_token), params: { code: "123456" } },
      -> { post candidate_status_withdraw_path(@rina_token) },
      -> { get candidate_status_path(@rina_token) }
    ].each do |request|
      request.call
      assert_response :not_found
    end
    assert_equal "pending", appointment.reload.confirmation
    assert_equal withdrawn_at.to_i, @rina.reload.consent_withdrawn_at.to_i, "the withdrawal time moved"
    assert_equal 0, OfferAccessCode.count
  end

  test "re-issue for one candidate revokes only that candidate's link, also when the same email applied twice" do
    other_job = portal_job
    open_portal(other_job)
    _rina_other, rina_other_token = submit!(other_job)
    Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example")
    assert_nil OneTimeLink.live("candidate_status", @rina_token)
    assert OneTimeLink.live("candidate_status", @budi_token), "another candidate's link was revoked"
    assert OneTimeLink.live("candidate_status", rina_other_token), "the same person's link for ANOTHER job was revoked"
  end

  test "re-issue answers identically whether or not the email applied (no enumeration)" do
    post link_requests_path, params: { job_code: @job.public_code, email: "rina@uji.example", commit: "Kirim link baru" }
    matched = [response.status, Nokogiri::HTML(response.body).at("main, body").text.squish]
    post link_requests_path, params: { job_code: @job.public_code, email: "tidak.ada@uji.example", commit: "Kirim link baru" }
    unmatched = [response.status, Nokogiri::HTML(response.body).at("main, body").text.squish]
    assert_equal matched, unmatched
    assert_equal 1, MailDelivery.where(kind: "status_link").count, "control: the matched request did send"
  end

  test "re-issue for a withdrawn application sends nothing and revives no link" do
    Portal::CandidateActions.new(@rina).withdraw_consent!
    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      Portal::ReissueLink.call(job_code: @job.public_code, email: "rina@uji.example")
    end
    assert_equal 0, OneTimeLink.where(subject: @rina, revoked_at: nil).count
  end

  test "the raw token is stored nowhere in the database and is mailed only in the status-link email" do
    Portal::ReissueLink.call(job_code: @job.public_code, email: "budi@uji.example")
    new_budi_token = ActionMailer::Base.deliveries.last.body.to_s[%r{/status/([A-Za-z0-9_\-]+)}, 1]
    assert new_budi_token, "control: the re-issue mail carries a token"
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    [@rina_token, @budi_token, new_budi_token].each do |token|
      tables.each do |table|
        text_columns = conn.columns(table).select { |c| %i[string text jsonb].include?(c.type) }.map(&:name)
        next if text_columns.empty?

        where = text_columns.map { |c| "#{conn.quote_column_name(c)}::text LIKE #{conn.quote("%#{token}%")}" }.join(" OR ")
        assert_equal 0, conn.select_value("SELECT count(*) FROM #{conn.quote_table_name(table)} WHERE #{where}").to_i,
                     "raw token found in #{table}"
      end
    end
    assert_equal OneTimeLink.digest(new_budi_token), OneTimeLink.where(subject: @budi, revoked_at: nil).sole.token_digest,
                 "control: the digest of the mailed token is what is stored"

    post candidate_status_offer_code_path(new_budi_token)
    ActionMailer::Base.deliveries.each do |mail|
      next if mail.subject.start_with?("Your application status link")

      [@rina_token, @budi_token, new_budi_token].each { |t| refute_includes mail.body.to_s, t, "token in '#{mail.subject}'" }
    end
  end

  test "every GET of the status page is logged with the link and the time only; POST actions are not opens" do
    appointment = appointment_for(@rina)
    link = OneTimeLink.find_by!(token_digest: OneTimeLink.digest(@rina_token))
    assert_difference -> { LinkOpen.where(one_time_link: link).count }, 1 do
      get candidate_status_path(@rina_token)
    end
    assert_equal %w[id one_time_link_id opened_at].sort, LinkOpen.column_names.sort, "a log row carries more than link and time"
    assert_no_difference -> { LinkOpen.count } do
      post candidate_status_confirm_path(@rina_token, appointment.id)
    end
  end
end
