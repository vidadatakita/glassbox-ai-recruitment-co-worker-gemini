require "test_helper"

# Independent test pass 3, three roles (GlassBox Team, 17 Oct 2026) on the screens and services the role
# rename touched: the brief (edit, complete), the fairness check screen, the step-9 / scoring / letter
# actions behind Progression.chooser?, interviewer links (every role), and the technical-test approval partial.
# superadmin passes every check; hr_admin prepares and decides; hr_manager reads (and scores the test,
# releases CVs, agrees salary: not exercised here). Retired role names must not pass any check.
#
# Mutants that should turn these red (none run on these files; they are outside the granted window):
#   JobBriefsController::EDITORS += :hr_manager        -> "the brief: hr_manager reads but cannot edit or complete"
#   Progression::CHOOSER_ROLES += "hr_manager"         -> "chooser? per role" and "every chooser action refuses ..."
#   Progression::CHOOSER_ROLES -= "superadmin"         -> "every chooser action lets hr_admin and superadmin past ..."
#   TestCases::Authority.may_approve? += hr_manager     -> "the approve partial ..."
class CupThreeRolesScreensTest < ActionDispatch::IntegrationTest
  RETIRED = %w[hr_pic consultant reviewer owner admin].freeze
  Actor = Struct.new(:id, :role)

  setup do
    Rails.cache.clear
    @super = staff_user("superadmin")
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
  end

  def no_access! = assert_redirected_to(staff_jobs_path) && assert_match(/do not have access/, flash[:alert])

  # --- The brief -------------------------------------------------------------------------------------

  test "the brief: superadmin and hr_admin edit a draft step over HTTP" do
    [@super, @admin].each do |user|
      job = briefed_job(complete: false)
      sign_in_as user
      get staff_job_brief_step_path(job, 1)
      assert_response :success, user.role
      patch staff_job_brief_step_path(job, 1), params: { brief: step1_params(title: "Edited by #{user.role}") }
      assert_response :redirect, user.role
      assert_equal "Edited by #{user.role}", job.reload.title, user.role
      sign_out
    end
  end

  test "the brief: superadmin and hr_admin complete it over HTTP" do
    [@super, @admin].each do |user|
      job = briefed_job(complete: false)
      sign_in_as user
      post staff_job_brief_complete_path(job)
      assert_redirected_to staff_job_brief_path(job)
      assert job.reload.brief_complete?, "#{user.role} could not complete a passing brief"
      assert_equal user.role, job.brief_changes.where(step: "complete").sole.actor_role
      sign_out
    end
  end

  test "the brief: hr_manager reads but cannot edit or complete" do
    job = briefed_job(complete: false)
    title = job.title
    sign_in_as @manager
    get staff_job_brief_path(job)
    assert_response :success
    get staff_job_brief_step_path(job, 1)
    no_access!
    patch staff_job_brief_step_path(job, 1), params: { brief: step1_params(title: "Edited by a manager") }
    no_access!
    post staff_job_brief_complete_path(job)
    no_access!
    job.reload
    assert_equal title, job.title
    assert_not job.brief_complete?
    assert_empty job.brief_changes.where(actor_id: @manager.id)
  end

  # --- Fairness check --------------------------------------------------------------------------------

  test "the fairness check screen opens for superadmin, hr_admin and hr_manager" do
    job = briefed_job
    [@super, @admin, @manager].each do |user|
      sign_in_as user
      get staff_job_fairness_check_path(job)
      assert_response :success, user.role
      sign_out
    end
  end

  # --- Progression.chooser? and the actions behind it ------------------------------------------------

  test "chooser? per role" do
    assert Progression.chooser?(@super)
    assert Progression.chooser?(@admin)
    assert_not Progression.chooser?(@manager)
    assert_not Progression.chooser?(nil)
    [nil, "visitor", *RETIRED].each { |role| assert_not Progression.chooser?(Actor.new(nil, role)), role.inspect }
  end

  # Each action, called by an actor, returns the role refusal message or nil (passed the role check).
  def role_refusal(actor)
    yield actor
    nil
  rescue Progression::Choose::Refused, Progression::InviteInterviewer::Refused, Progression::ScoreManual::Refused,
         Progression::ScoreInterview::Refused, Progression::Letters::Refused => e
    e.message.start_with?("Only the HR Admin") ? e.message : nil
  end

  def chooser_actions(participation)
    application = participation.job_application
    {
      choose: ->(a) { Progression::Choose.call(participation:, actor: a, choice: "lanjut", seen_recommendation_id: nil) },
      score_manual: ->(a) { Progression::ScoreManual.call(participation:, actor: a, attendance: "hadir", value: "70") },
      score_interview: ->(a) { Progression::ScoreInterview.call(participation:, actor: a, attendance: "hadir") },
      letters_draft: ->(a) { Progression::Letters.stub(:kind_for, "rejection") { Progression::Letters.draft(application:, actor: a) } },
      letters_send: ->(a) { Progression::Letters.stub(:kind_for, "rejection") { Progression::Letters.send!(application:, actor: a, subject: "", body: "") } }
    }
  end

  def a_participation
    set_retention
    publish_consent(at: 2.days.ago)
    job = portal_job
    open_portal(job)
    application, = submit!(job)
    application.participations.first
  end

  test "every chooser action refuses hr_manager, a nil role, an unknown role and every retired name" do
    actions = chooser_actions(a_participation)
    outsiders = [@manager, Actor.new(nil, nil), Actor.new(nil, "visitor"), *RETIRED.map { |r| Actor.new(nil, r) }]
    actions.each do |name, action|
      outsiders.each do |actor|
        assert_not_nil role_refusal(actor) { |a| action.call(a) }, "#{name} let #{actor.role.inspect} past the role check"
      end
    end
  end

  test "every chooser action lets hr_admin and superadmin past the role check" do
    actions = chooser_actions(a_participation)
    actions.each do |name, action|
      [@admin, @super].each do |actor|
        assert_nil role_refusal(actor) { |a| action.call(a) }, "#{name} refused #{actor.role} on role"
      end
    end
  end

  # Interviewer links: every staff role since the team decision of 17 Oct 2026 (Progression::INVITER_ROLES,
  # user-role-16102026.md step 10); the step decision stays with chooser?. Unknown and retired roles never.
  test "every staff role may invite an assessor; nil, unknown and retired roles may not" do
    participation = a_participation
    invite = ->(actor) do
      Progression::InviteInterviewer.call(participation:, actor:, name: "Invented Assessor")
      nil
    rescue Progression::InviteInterviewer::Refused => e
      e.message
    end
    [@super, @admin, @manager].each do |actor|
      assert_no_match(/Sign in as staff/, invite.call(actor).to_s, actor.role)
    end
    [Actor.new(nil, nil), Actor.new(nil, "visitor"), *RETIRED.map { |r| Actor.new(nil, r) }].each do |actor|
      assert_match(/Sign in as staff/, invite.call(actor).to_s, actor.role.inspect)
    end
  end

  # --- Technical-test approval partial ---------------------------------------------------------------

  test "the approve partial shows a draft version's approval to superadmin and hr_admin, never to hr_manager" do
    job = briefed_job(package: 3, complete: false, test_case: false)
    saved = TestCases::SaveVersion.call(job:, actor: @admin, params: case_version_params(job))
    assert saved.ok?, saved.errors.inspect
    approve_url = staff_job_test_case_approve_path(job, saved.test_case)
    { @super => 1, @admin => 1, @manager => 0 }.each do |user, count|
      sign_in_as user
      get staff_job_test_case_step_path(job)
      assert_response :success, user.role
      assert_select "form[action=?]", approve_url, count, "#{user.role}: approve forms"
      doc = Nokogiri::HTML(response.body)
      doc.css("form").each { |form| assert_empty form.css("form"), "nested form for #{user.role}" }
      assert_empty doc.css("form[action='#{approve_url}'] [disabled]")
      sign_out
    end
    sign_in_as @manager
    post approve_url, params: { content_digest: saved.test_case.content_digest }
    no_access!
    assert saved.test_case.reload.draft?, "hr_manager approved a version"
  end
end
