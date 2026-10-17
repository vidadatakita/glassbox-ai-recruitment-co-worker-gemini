require "test_helper"

# Owner requirement, 17 Oct 2026: "the superadmin can do the processes post, screening, select and
# close". This file proves it over HTTP, signed in as ONE superadmin person (staff_user("superadmin")),
# through every state-changing action of the four phases, asserting what was PERSISTED each time (a
# redirect alone proves nothing: every refusal here also redirects).
#
# Every phase carries a control: a non-superadmin of the role that does NOT own the action is refused
# the same request, so a regression that let everyone through (or a test that cannot fail) shows red.
#
# The per-PERSON rule binds the superadmin too: whoever releases a CV to the AI (or scores a
# technical test) is never the vacancy's consultant (jobs.consultant_id). That refusal is intended
# and has its own test below.
#
# Phases are separate test methods so a refusal in one phase does not hide the result of the next.
# Where a later phase needs state an earlier phase builds, the setup goes through the same services
# the factories use, acted by an HR admin; only the action under test is the superadmin's.
class SuperadminWalkTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ScreeningFactory
  include TechnicalTestFactory

  setup do
    Rails.cache.clear
    company # the one client company exists before the superadmin (no company of its own) creates a job
    set_retention
    publish_consent
    @superadmin = staff_user("superadmin")
  end

  def brief_params(hash) = { brief: hash }

  def flash_alert = flash[:alert].to_s

  # A redirect's flash survives into the NEXT request, so a control's "You do not have access" would
  # still be in flash when the superadmin's request is checked. Following the redirect consumes it.
  def consume_flash! = (follow_redirect! if response.redirect?)

  # POST phase through the screens, as the superadmin: brief steps 1-4, the technical-test case (step 5,
  # upload and approval), "Complete brief", the job ad, and "Open the applicant portal". Returns the job.
  # The AI is switched off for the brief and the ad: Briefs::Complete and Briefs::SaveAd run an AI
  # pass when it is on (job_form_test stubs it for the same reason); the rule pass still runs.
  def post_vacancy_as_superadmin!
    sign_in_as @superadmin
    Screening::Config.stub(:enabled?, false) do
      assert_difference -> { Job.count }, 1 do
        post staff_create_job_path, params: brief_params(step1_params(title: "Operator Superadmin"))
      end
      job = Job.order(:id).last
      assert_redirected_to staff_job_brief_step_path(job, 2)
      patch staff_job_brief_step_path(job, 2), params: brief_params(step2_params)
      patch staff_job_brief_step_path(job, 3), params: brief_params(step3_params)
      patch staff_job_brief_step_path(job, 4), params: brief_params(step4_params(package: 3)).merge(lanjut: "1")
      assert_redirected_to staff_job_test_case_step_path(job), "package 3 runs S2, so step 5 comes next"

      # Step 5 is a two-person step for everyone (TestCases::Authority, rule 19): whoever may EDIT the
      # case is shown the upload form, not the approval, so nobody approves their own upload. The
      # vacancy's consultant (another HR admin person) uploads it, through the same service as
      # approved_test_case!; the superadmin approves it on the screen. Setup, not the action under test.
      job.update!(consultant: staff_user("consultant"))
      saved = TestCases::SaveVersion.call(job:, actor: staff_user("consultant"), params: case_version_params(job))
      assert saved.ok?, "test case refused: #{saved.errors.inspect}"
      test_case = saved.test_case
      get staff_job_test_case_step_path(job)
      digest = css_select("form.test-case-approve input[name=content_digest]").first&.[]("value")
      assert digest, "the superadmin is offered the approval of the case"
      post staff_job_test_case_approve_path(job, test_case), params: { content_digest: digest }
      assert_redirected_to staff_job_test_case_step_path(job)
      assert test_case.reload.approved?, "the superadmin approved the technical-test case"
      assert_equal @superadmin.id, test_case.approved_by_id

      post staff_job_brief_complete_path(job)
      assert_redirected_to staff_job_brief_path(job)
      assert job.reload.brief_complete?, "the superadmin completed the brief: #{flash_alert}"
      assert_equal @superadmin.id, job.brief_changes.find_by!(step: "complete").actor_id

      post staff_job_ad_path(job), params: { ad_text: "Kami mencari operator untuk tim gudang di Bekasi." }
      assert_redirected_to staff_job_path(job, anchor: "applicant-portal")
      assert_equal "Kami mencari operator untuk tim gudang di Bekasi.", job.reload.ad_text
      assert_nil job.ad_approved_at, "the ad is not live before the portal opens"
      job
    end
  end

  def open_portal_as_superadmin!(job)
    sign_in_as @superadmin
    post staff_job_portal_open_path(job)
    assert_redirected_to staff_job_path(job)
    assert_nil flash[:alert], "portal open refused for the superadmin"
    job.reload
  end

  # ---------------------------------------------------------------------------------------------
  # 1. POST
  # ---------------------------------------------------------------------------------------------

  test "POST: the superadmin writes the brief, the case, completes it, saves the ad and opens the portal; an HR manager is refused each" do
    job = post_vacancy_as_superadmin!
    sign_out

    # Control: an HR manager is refused the same POST actions. Run BEFORE the superadmin opens the
    # portal, because the first open is once-only and afterwards refuses everyone.
    manager = staff_user("hr_manager")
    sign_in_as manager
    post staff_job_ad_path(job), params: { ad_text: "Teks dari HR manager." }
    assert_redirected_to staff_jobs_path
    assert_equal "Kami mencari operator untuk tim gudang di Bekasi.", job.reload.ad_text, "an HR manager changed the ad"
    consume_flash!
    post staff_job_portal_open_path(job)
    assert_equal "Only the HR Admin can open the portal.", flash_alert
    refute ApplicationWindow.new(job.reload).open?, "an HR manager opened the portal"
    assert_nil job.ad_approved_at
    draft = briefed_job(package: 3, complete: false)
    post staff_job_brief_complete_path(draft)
    assert_redirected_to staff_jobs_path
    refute draft.reload.brief_complete?, "an HR manager completed a brief"
    consume_flash!
    sign_out

    open_portal_as_superadmin!(job)
    assert_equal @superadmin.id, job.ad_approved_by_id, "opening the portal approved the ad under the superadmin's name"
    assert job.ad_approved_at
    assert ApplicationWindow.new(job).open?, "the applicant portal is open"
    event = job.application_window_events.order(:id).last
    assert_equal ["open", @superadmin.id, "superadmin"], [event.action, event.actor_id, event.actor_role]
  end

  # ---------------------------------------------------------------------------------------------
  # 2. SCREENING
  # ---------------------------------------------------------------------------------------------

  test "SCREENING: the superadmin starts the screening and sends the CV to Gemini; a result is stored; HR admin and HR manager are refused their counterpart" do
    job = post_vacancy_as_superadmin!
    open_portal_as_superadmin!(job)
    # The vacancy's consultant (set in post_vacancy_as_superadmin!) is another person, so the
    # per-person rule does not bind the superadmin.
    assert_equal staff_user("consultant").id, job.consultant_id
    fake = FakeGemini.new
    with_ai(fake) do
      participation = apply_with_cv!(job)
      perform_enqueued_jobs

      # Control: an HR manager may not start the screening (an HR admin action).
      sign_in_as staff_user("hr_manager")
      post staff_job_screening_start_path(job)
      assert_equal "You do not have access to this action.", flash_alert

      sign_in_as @superadmin
      post staff_job_screening_start_path(job)
      assert_redirected_to staff_job_path(job, anchor: "screening")
      assert_match(/\d+ application\(s\) queued for screening/, flash[:notice].to_s)
      perform_enqueued_jobs
      assert_equal "awaiting_release", participation.reload.screening_state, "the CV waits for a person to release it"
      release = AiRelease.latest_for(participation)
      assert release&.pending?, "a pending release exists after the start"

      # Control: an HR admin may not send a CV to Gemini (an HR manager action).
      sign_in_as staff_user("hr_pic")
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256 }
      assert_redirected_to staff_jobs_path
      assert_nil release.reload.action, "an HR admin released the CV"
      assert_equal 0, fake.requests.size

      sign_in_as @superadmin
      fake.push(gemini_message(criteria_for(job)))
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256 }
      assert_redirected_to staff_job_ai_releases_path(job), "release refused: #{flash_alert}"
      action = release.reload.action
      assert_equal ["released", @superadmin.id], [action&.action, action&.actor_id]
      perform_enqueued_jobs
      assert_equal 1, fake.requests.size, "the released text went to Gemini once"
      assert_equal "done", participation.reload.screening_state
      assert ScreeningResult.exists?(participation_id: participation.id), "a screening result is stored"
    end
  end

  # Intended refusal: the per-person rule binds the superadmin as it binds everyone.
  test "SCREENING: the superadmin who IS the vacancy's consultant is refused the release (per-person rule)" do
    job = screening_job(consultant: @superadmin)
    fake = FakeGemini.new
    with_ai(fake) do
      participation = apply_with_cv!(job)
      perform_enqueued_jobs
      release = AiRelease.latest_for(participation)
      assert release&.pending?
      sign_in_as @superadmin
      post staff_ai_release_send_path(release), params: { confirmed: "1", payload_sha256: release.payload_sha256 }
      assert_redirected_to staff_ai_release_path(release)
      assert_equal "The reviewer cannot be the consultant of this vacancy.", flash_alert
      assert_nil release.reload.action
      assert_equal 0, fake.requests.size, "nothing was sent to Gemini"
      assert_equal "awaiting_release", participation.reload.screening_state
    end
  end

  # ---------------------------------------------------------------------------------------------
  # 3. SELECT
  # ---------------------------------------------------------------------------------------------

  test "SELECT: the superadmin records the step-9 decision (Continue); an HR manager is refused" do
    job = technical_test_job(open_gate: false)
    application, = applicant!(job)
    s1 = s1_of(application)

    sign_in_as staff_user("hr_manager")
    post staff_participation_choice_path(s1), params: { choice: "lanjut" }
    assert_redirected_to staff_jobs_path
    assert_nil s1.reload.progression_choice, "an HR manager recorded the step-9 decision"

    sign_in_as @superadmin
    post staff_participation_choice_path(s1), params: { choice: "lanjut", note: "" }
    assert_redirected_to staff_application_path(application, anchor: "stage-#{s1.id}")
    choice = s1.reload.progression_choice
    assert choice, "the superadmin's step-9 decision was not recorded: #{flash_alert}"
    assert_equal ["lanjut", @superadmin.id], [choice.direction, choice.actor_id]
    assert application.participations.joins(:stage).exists?(stages: { code: "S3" }), "the candidate entered Interview 1"
  end

  # Every role may create an interviewer's link (17 Oct 2026), so the control is a signed-out visitor.
  test "SELECT: the superadmin creates an interviewer link; a signed-out visitor is refused" do
    job = technical_test_job(open_gate: false)
    application, = applicant!(job)
    # Setup, not the action under test: an HR admin's Continue on S1 brings the candidate to S3.
    Progression::Choose.call(participation: s1_of(application), actor: staff_user("hr_pic"), choice: "lanjut", seen_recommendation_id: nil)
    s3 = application.participations.joins(:stage).find_by!(stages: { code: "S3" })

    assert_no_difference -> { InterviewerInvite.count } do
      post staff_participation_interviewer_path(s3), params: { interviewer_name: "Anonymous Assessor" }
    end
    assert_redirected_to new_session_path

    sign_in_as @superadmin
    post staff_participation_interviewer_path(s3), params: { interviewer_name: "Test Assessor" }
    assert_redirected_to staff_application_path(application, anchor: "stage-#{s3.id}")
    invite = InterviewerInvite.find_by(participation: s3)
    assert invite, "the superadmin's interviewer link was not created: #{flash_alert}"
    assert_equal ["Test Assessor", @superadmin.id], [invite.interviewer_name, invite.issued_by_id]
    assert flash[:interviewer_link].present?, "the link is shown once"
  end

  test "SELECT: the superadmin scores the technical test (S2); an HR admin is refused" do
    job = technical_test_job # gate open; the consultant is another person (staff_user("consultant"))
    application, = applicant!(job)
    attempt = answered!(application)
    ratings = ratings_for(attempt, [5, 5])

    sign_in_as staff_user("hr_pic")
    post staff_test_attempt_score_path(attempt), params: { ratings:, note: "Dari HR admin." }
    assert_redirected_to staff_jobs_path
    assert_empty s2_of(application).score_entries, "an HR admin scored the technical test"
    consume_flash!

    sign_in_as @superadmin
    post staff_test_attempt_score_path(attempt), params: { ratings:, note: "Semua selisih ditemukan." }
    assert_redirected_to staff_job_test_scorings_path(job)
    assert_nil flash[:alert], "scoring refused for the superadmin"
    s2 = s2_of(application)
    assert_equal [@superadmin.id], s2.score_entries.map(&:entered_by_id).uniq
    assert_equal "pass", s2.current_decision&.outcome
  end

  test "SELECT: the superadmin agrees the salary; an HR admin is refused" do
    job = technical_test_job(open_gate: false)
    job.update_columns(salary_min: 5_200_000, salary_max: 6_000_000)
    application, = applicant!(job)
    hr = staff_user("hr_pic")
    # Setup, not the action under test: an HR admin passes the candidate through every stage (copied
    # from test/services/salary_test.rb), so the salary step is reached.
    Screening::Config.stub(:enabled?, false) do
      loop do
        step = application.reload.participations.select { |p| Progression.step?(p) && p.progression_choice.nil? }
                          .min_by { |p| Progression.order_of(p.stage) }
        step.stage.score_source == "scorecard" && job.competencies.exists?(stage_code: step.stage.code) &&
          Progression::ScoreInterview.call(participation: step, actor: hr, attendance: "attended",
                                           ratings: job.competencies.where(stage_code: step.stage.code).to_h { |c| [c.id.to_s, "4"] })
        Progression::Choose.call(participation: step, actor: hr, choice: "lanjut", seen_recommendation_id: StageRecommendation.latest_for(step)&.id)
        break if Progression::Salary.ready?(application.reload)
      end
    end

    sign_in_as hr
    post staff_application_salary_path(application), params: { amount: "5.600.000", note: "" }
    assert_redirected_to staff_jobs_path
    assert_equal 0, SalaryAgreement.where(job_application: application).count, "an HR admin agreed the salary"

    sign_in_as @superadmin
    post staff_application_salary_path(application), params: { amount: "5.600.000", note: "" }
    assert_redirected_to staff_application_path(application, anchor: "salary")
    agreement = SalaryAgreement.find_by(job_application: application)
    assert agreement, "the superadmin's salary agreement was not recorded: #{flash_alert}"
    assert_equal [5_600_000, @superadmin.id, false], [agreement.agreed_amount, agreement.decided_by_id, agreement.outside_band]
  end

  # ---------------------------------------------------------------------------------------------
  # 4. CLOSE
  # ---------------------------------------------------------------------------------------------

  # Only the portal close exists: config/routes.rb has no stage-close action (stages close through
  # their own lifecycle, not a staff button), so there is nothing else to prove in this phase.
  test "CLOSE: the superadmin closes the applicant portal with a reason; an HR manager is refused" do
    job = post_vacancy_as_superadmin!
    open_portal_as_superadmin!(job)

    sign_in_as staff_user("hr_manager")
    post staff_job_portal_close_path(job), params: { reason: "Dari HR manager." }
    assert_equal "Only the HR Admin can close the portal.", flash_alert
    assert ApplicationWindow.new(job.reload).open?, "an HR manager closed the portal"
    consume_flash!

    sign_in_as @superadmin
    post staff_job_portal_close_path(job), params: { reason: "Kuota pelamar sudah cukup." }
    assert_redirected_to staff_job_path(job)
    assert_nil flash[:alert], "portal close refused for the superadmin"
    refute ApplicationWindow.new(job.reload).open?, "the applicant portal is closed"
    event = job.application_window_events.order(:id).last
    assert_equal ["close", "Kuota pelamar sudah cukup.", @superadmin.id, "superadmin"],
                 [event.action, event.reason, event.actor_id, event.actor_role]
  end
end
