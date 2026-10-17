require "test_helper"

# 18 Oct 2026 (Vida): a draft whose competency test started while the portal was open is still sent at
# the end of its test, even if the portal closed since (the automatic send passes after_close: true). A
# manual Send after closing is still refused; a closed first stage refuses both; the purge waits for the
# automatic send.
class ApplyAfterCloseTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include BankFlowHelpers

  def started_draft!(email)
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name: "Uji #{email}", email:, phone: "081234567890", consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    post apply_test_start_path(@job.public_code, secret)
    ApplicationDraft.find_by_secret(@job, secret)
  end

  def close_portal! = Portal::WindowChange.close!(job: @job, actor: @consultant, reason: "Enough applicants")

  test "after the portal closes: a manual Send is refused, the automatic send goes through" do
    draft = started_draft!("late@uji.example")
    close_portal!
    refute ApplicationWindow.new(@job).open?
    assert_raises(Portal::SubmitApplication::Closed) { ApplicationDrafts::Submit.call(draft: draft.reload) }
    assert_nil draft.reload.submitted_at, "the refused manual send left the draft untouched"
    assert_difference -> { JobApplication.count }, 1 do
      result = ApplicationDrafts::Submit.call(draft:, after_close: true)
      assert result.errors.empty?, result.errors.inspect
    end
    assert draft.reload.submitted?
  end

  test "a draft that never started its test is not sent after closing, even by the automatic send" do
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name: "Uji early", email: "early@uji.example", phone: "081234567890", consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    draft = ApplicationDraft.order(:id).last
    close_portal!
    result = ApplicationDrafts::Submit.call(draft:, after_close: true)
    refute result.errors.empty?, "no CV, no test: refused before the window matters"
    assert_nil draft.reload.submitted_at
  end

  test "a closed first stage refuses even the automatic send" do
    draft = started_draft!("stage@uji.example")
    close_portal!
    @job.stages.where.not(code: "RC").order(:code).first.update_columns(status: "closed")
    assert ApplicationWindow.new(@job).first_stage_closed?
    assert_raises(Portal::SubmitApplication::Closed) { ApplicationDrafts::Submit.call(draft:, after_close: true) }
    assert_nil draft.reload.submitted_at
  end

  test "the purge keeps a started draft until two hours after its deadline, then deletes it" do
    draft = started_draft!("purge@uji.example")
    close_portal!
    assert_equal 0, ApplicationDrafts::Purge.call(now: draft.answer_deadline + 1.hour)
    assert ApplicationDraft.exists?(draft.id)
    assert_equal 1, ApplicationDrafts::Purge.call(now: draft.answer_deadline + 3.hours)
    refute ApplicationDraft.exists?(draft.id)
  end
end
