require "test_helper"
require_relative "apply_engine_helpers"

# Independent test pass, three-step application slice B: the secret link, Submit (once, through the
# portal checks, after time-up), what the applicant sees afterwards (no old 48-hour case test, no
# score), the closed portal, the purge, the old two-step form, and the house rules on every new page.
class ApplyFlowEngineTest < ActionDispatch::IntegrationTest
  include ApplyEngineHelpers

  def submitted!(job, **kw)
    draft, secret = three_step_started!(job, **kw)
    mc = draft.questions.select(&:multiple_choice?)
    post apply_answers_path(job.public_code, secret), params: { answers: { mc[0].id => "0", mc[1].id => "1" } }, xhr: true
    post apply_submit_path(job.public_code, secret)
    assert_response :success
    [draft.reload, secret, mc]
  end

  def status_token(application) = OneTimeLink.issue!(subject: application, purpose: "candidate_status").last

  # --- (1) secrets -----------------------------------------------------------------------------------

  test "a secret only opens its own draft on its own vacancy; a submitted draft's link stores nothing more" do
    job = three_step_job!
    other = three_step_job!
    draft, secret = three_step_open!(job)
    get apply_cv_path(job.public_code, secret)
    assert_response :success # control
    get apply_cv_path(other.public_code, secret)
    assert_response :not_found, "a valid secret under another vacancy's code"
    get apply_cv_path(job.public_code, draft.id.to_s)
    assert_response :not_found, "the draft id is not a key"
    get apply_cv_path(job.public_code, draft.token_digest)
    assert_response :not_found, "the stored digest is not a key"
    post apply_test_start_path(job.public_code, secret.chop + (secret[-1] == "A" ? "B" : "A"))
    assert_response :not_found
    refute draft.reload.test_started?

    sent, sent_secret, = submitted!(job, email: "lina@contoh.example")
    assert_no_difference [-> { JobApplication.count }, -> { DraftAnswer.where(application_draft: sent).maximum(:updated_at).to_f }] do
      post apply_submit_path(job.public_code, sent_secret)
      assert_includes response.body, "already been sent"
      post apply_answers_path(job.public_code, sent_secret), params: { answers: { sent.draw.first => "1" } }, xhr: true
      post apply_cv_path(job.public_code, sent_secret), params: { lamaran: { cv: three_step_pdf } }
    end
    refute sent.reload.cv.attached?
  end

  # --- (2) start/submit order ------------------------------------------------------------------------

  test "the test cannot start without a CV; Submit without a CV or without a started test stores nothing (422)" do
    job = three_step_job!
    draft, secret = three_step_open!(job)
    post apply_test_start_path(job.public_code, secret)
    assert_redirected_to apply_cv_path(job.public_code, secret)
    refute draft.reload.test_started?
    assert_no_difference -> { JobApplication.count } do
      post apply_submit_path(job.public_code, secret)
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Upload your CV first"

    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    assert_no_difference -> { JobApplication.count } do
      post apply_submit_path(job.public_code, secret)
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Start the competency test first"
  end

  # --- (4) submit ------------------------------------------------------------------------------------

  test "Submit: one application, the draft cleared, the CV blob moved, MC scored by the key, S2 attended" do
    job = three_step_job!
    draft, secret, mc = submitted!(job)
    app = draft.job_application
    assert_equal ["Sari Handayani", "sari@contoh.example", "081298765432"], [app.candidate.name, app.candidate.email, app.candidate.phone]
    assert_equal({ "name" => nil, "email" => nil, "phone" => nil, "domicile_city" => nil, "expected_salary_min" => nil, "expected_salary_max" => nil },
                 draft.attributes.slice(*%w[name email phone domicile_city expected_salary_min expected_salary_max]))
    refute draft.cv.attached?
    assert app.cv.attached?
    assert_equal PortalFactory::PDF_BYTES, app.cv.download
    assert_equal [true, false], mc.first(2).map { |q| draft.answers.find_by!(bank_question: q).correct }
    assert(draft.answers.where.not(bank_question_id: mc.first(2).map(&:id)).all? { |a| a.correct.nil? })
    assert_equal "attended", TechnicalTests.participation_for(app).attendance
    assert_equal draft.consent_template_id, app.consent_template_id
    assert_equal draft.consent_at.to_i, app.consent_at.to_i
  end

  test "a double submit (sequential, and with a stale copy of the draft as in a race) leaves exactly one application" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    stale = ApplicationDraft.find(draft.id)
    stale.cv.attached? # the racing request already passed its checks
    assert_difference -> { JobApplication.count }, 1 do
      post apply_submit_path(job.public_code, secret)
      post apply_submit_path(job.public_code, secret)
    end
    outcome = begin
      ApplicationDrafts::Submit.call(draft: stale).tap { |r| puts "\n[observed] the racing copy got: #{r.errors.inspect}" }
    rescue => e
      e
    end
    assert_equal 1, JobApplication.where(job:).count, "still one application after the racing copy"
    assert_kind_of ApplicationDrafts::Submit::Result, outcome,
                   "the second racer must get a refusal, not an exception (got #{outcome.class}: #{outcome.message if outcome.is_a?(Exception)})"
  end

  test "time up: Submit still sends the saved answers and ignores answers posted after the grace" do
    travel_to Time.zone.parse("2026-10-20 09:00:00")
    job = three_step_job!
    draft, secret = three_step_started!(job)
    q1, q2 = draft.questions.select(&:multiple_choice?).first(2)
    post apply_answers_path(job.public_code, secret), params: { answers: { q1.id => "0" } }, xhr: true
    travel_to draft.test_due_at + draft.grace_seconds.seconds + 1.second
    get apply_test_path(job.public_code, secret)
    assert_select "fieldset.apply-question[disabled]", draft.draw.size # reported: inputs locked after time-up
    assert_select "button[disabled]", 0
    assert_difference -> { JobApplication.count }, 1 do
      post apply_submit_path(job.public_code, secret), params: { answers: { q1.id => "1", q2.id => "0" } }
    end
    draft.reload
    assert_equal [q1.id], draft.answers.pluck(:bank_question_id), "the posted late answer to q2 is not stored"
    assert_equal 0, draft.answers.first.choice_index, "the saved answer to q1 is not overwritten"
  end

  # Each check is recorded, then all are asserted together, so one red does not hide the others.
  def old_case_test_surface(job)
    travel_to Time.zone.parse("2026-10-20 09:00:00")
    draft, = submitted!(job)
    app = draft.job_application
    token = status_token(app)
    problems = []
    get candidate_status_path(token)
    problems << "status page offers 'Take the technical test'" if response.body.include?("Take the technical test")
    problems << "status page says 'Not started, start by'" if response.body.include?("Not started, start by")
    problems << "Status#state is #{TechnicalTests::Status.new(app).state.inspect}" if %i[not_started expired].include?(TechnicalTests::Status.new(app).state)
    travel 25.hours
    ActionMailer::Base.deliveries.clear
    TechnicalTests::Notices.reminder(app.reload)
    problems << "a 'test_reminder' e-mail was sent 25 h after submit" if ActionMailer::Base.deliveries.any?
    travel 24.hours
    TechnicalTests::Expire.sweep
    TechnicalTests::Expire.call(app.reload)
    participation = TechnicalTests.participation_for(app).reload
    problems << "attendance became #{participation.attendance}" unless participation.attendance == "attended"
    problems << "a decision #{participation.current_decision.reason_code} was written" if participation.current_decision
    get candidate_status_path(token)
    problems << "49 h later the status page says 'Not taken'" if response.body.include?("Not taken")
    problems
  end

  test "after a three-step Submit on a vacancy that ALSO has an approved case: no old 48-hour test is offered, reminded or expired" do
    assert_empty old_case_test_surface(three_step_job!)
  end

  test "after a three-step Submit on a bank-only vacancy: no old 48-hour test is offered, reminded or expired" do
    assert_empty old_case_test_surface(bank_only_job!)
  end

  test "the applicant never sees a score or the answer key: not on the test page, not after Submit" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    get apply_test_path(job.public_code, secret)
    body = response.body
    refute_match(/correct|score|nilai|skor/i, body.gsub(/apply-question|incorrect\b/, ""))
    refute_match(/data-correct|correct_index/, body)
    post apply_submit_path(job.public_code, secret)
    refute_match(/\bcorrect\b|\bscore\b|\d+\s*(of|dari)\s*\d+\s*(correct|benar)/i, response.body)
    get candidate_status_path(status_token(draft.reload.job_application))
    refute_match(/\bcorrect\b|\bscore\b|\bbenar\b/i, response.body)
  end

  test "a knockout question added after step 1 strands the draft: Submit refuses and no route returns to step 1" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    job.knockout_questions.create!(position: 9, text: "Bersedia ditempatkan di Cikarang?")
    assert_no_difference -> { JobApplication.count } do
      post apply_submit_path(job.public_code, secret)
    end
    assert_response :unprocessable_entity
    assert_includes response.body, "Answer every requirement question"
    refute draft.reload.submitted?
    # The error is shown on the test page, which has no requirement questions to answer.
    assert_select "input[name^='knockout']", 0
  end

  # --- portal closed / quota -------------------------------------------------------------------------

  test "Submit after the portal closed: 410, nothing stored, the draft kept until the purge" do
    job = three_step_job!
    draft, secret = three_step_started!(job)
    Portal::WindowChange.close!(job:, actor: staff_user("hr_pic"))
    assert_no_difference [-> { JobApplication.count }, -> { Candidate.count }] do
      post apply_submit_path(job.public_code, secret)
    end
    assert_response :gone
    assert ApplicationDraft.exists?(draft.id)
    get apply_test_path(job.public_code, secret)
    assert_response :success # a GET on a closed portal shows the closed page
    assert_empty Nokogiri::HTML(response.body).css("form[action$='/submit']"), "the closed page offers no Submit form"

    # Every other step refuses too (the guard is per request, not only inside Submit's lock).
    post apply_answers_path(job.public_code, secret), params: { answers: { draft.draw.first => "0" } }, xhr: true
    assert_response :gone
    assert_equal 0, draft.answers.count
    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    assert_response :gone
    assert_no_difference -> { ApplicationDraft.count } do
      post apply_start_path(job.public_code), params: { lamaran: { name: "Late", email: "late@contoh.example", phone: "081298765432", consent: "1",
                                                                  consent_token: shown_consent_token }, knockout: answers_for(job) }
    end
    assert_response :gone
  end

  test "the last quota place: two drafts, one place, one application; the second gets 410 and stores nothing" do
    job = three_step_job!
    Portal::WindowChange.close!(job:, actor: staff_user("hr_pic"))
    Portal::WindowChange.reopen!(job:, actor: staff_user("hr_pic"), reason: "One place left", quota: 1)
    _a, secret_a = three_step_started!(job, email: "a@contoh.example")
    _b, secret_b = three_step_started!(job, email: "b@contoh.example")
    post apply_submit_path(job.public_code, secret_a)
    assert_response :success
    assert_no_difference -> { JobApplication.count } do
      post apply_submit_path(job.public_code, secret_b)
    end
    assert_response :gone
    assert_equal 1, job.job_applications.count
  end

  # --- (7) purge -------------------------------------------------------------------------------------

  test "the purge deletes unsubmitted drafts and their CV once the portal closed; keeps submitted ones and open portals" do
    open_job = three_step_job!
    closed_job = three_step_job!
    kept_open, = three_step_started!(open_job, email: "open@contoh.example")
    gone, = three_step_started!(closed_job, email: "gone@contoh.example")
    sent, = submitted!(closed_job, email: "sent@contoh.example")
    gone_blob = gone.cv.blob
    sent_blob = sent.job_application.cv.blob
    Portal::WindowChange.close!(job: closed_job, actor: staff_user("hr_pic"))

    assert_equal 1, ApplicationDrafts::Purge.call
    refute ApplicationDraft.exists?(gone.id)
    refute ActiveStorage::Blob.exists?(gone_blob.id), "the unsent CV is deleted with the draft"
    assert_equal 0, DraftAnswer.where(application_draft_id: gone.id).count
    assert ApplicationDraft.exists?(kept_open.id), "an open portal's draft is untouched"
    assert kept_open.reload.cv.attached?
    assert ApplicationDraft.exists?(sent.id), "a submitted draft keeps the test"
    assert ActiveStorage::Blob.exists?(sent_blob.id)
    assert_equal PortalFactory::PDF_BYTES, sent.job_application.reload.cv.download, "the application's CV survives the draft detach and the purge"
    assert_equal 0, ApplicationDrafts::Purge.call, "idempotent"
  end

  # --- (5) old form ----------------------------------------------------------------------------------

  test "bank vacancy: the two-step show, check and create redirect to the three-step form and store nothing" do
    job = three_step_job!
    get lamar_path(job.public_code, ch: "ig")
    assert_redirected_to apply_start_path(job.public_code, ch: "ig")
    assert_no_difference [-> { JobApplication.count }, -> { Candidate.count }] do
      post lamar_check_path(job.public_code), params: { knockout: answers_for(job) }
      assert_redirected_to apply_start_path(job.public_code)
      post lamar_path(job.public_code), params: { lamaran: application_params(job).merge(consent_token: shown_consent_token), knockout: answers_for(job) }
      assert_redirected_to apply_start_path(job.public_code)
    end
  end

  test "non-bank vacancy: the three-step address sends to the two-step form, which still stores an application" do
    job = technical_test_job
    assert_nil QuestionBank.current_for(job)
    get apply_start_path(job.public_code)
    assert_redirected_to lamar_path(job.public_code)
    assert_no_difference -> { ApplicationDraft.count } do
      post apply_start_path(job.public_code), params: { lamaran: { name: "X" } }
    end
    assert_redirected_to lamar_path(job.public_code)
    get lamar_path(job.public_code)
    assert_response :success
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")&.[]("value") || shown_consent_token
    assert_difference -> { JobApplication.count }, 1 do
      post lamar_path(job.public_code), params: { lamaran: application_params(job).merge(consent_token: token).except(:knockout), knockout: answers_for(job) }
    end
  end

  # --- (6) house rules -------------------------------------------------------------------------------

  test "every new page: no form inside a form, no disabled button, every named button has a value; errors render 422" do
    job = three_step_job!
    pages = []
    get apply_start_path(job.public_code)
    pages << response.body
    draft, secret = three_step_open!(job)
    get apply_cv_path(job.public_code, secret)
    pages << response.body
    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: three_step_pdf } }
    get apply_test_path(job.public_code, secret)
    pages << response.body
    post apply_test_start_path(job.public_code, secret)
    get apply_test_path(job.public_code, secret)
    pages << response.body
    pages.each_with_index do |html, i|
      doc = Nokogiri::HTML(html)
      assert_equal html.scan(/<form\b/).size, doc.css("form").size, "page #{i}: a form inside a form"
      assert_empty doc.css("button[disabled], input[type=submit][disabled]"), "page #{i}: a disabled submit"
      doc.css("button[name]").each { |b| refute_empty b["value"].to_s, "page #{i}: button #{b["name"]} without a value" }
      doc.css("form").each { |f| assert_equal 1, f.css("input[name=authenticity_token]").size, "page #{i}: CSRF token once" } if html.include?("authenticity_token")
    end
    save = Nokogiri::HTML(pages.last).at("button[formaction]")
    assert_equal "apply-test-form", save["form"], "Save answers sits outside the form and targets it"

    bad = three_step_details(job)
    bad[:lamaran][:email] = "not-an-email"
    post apply_start_path(job.public_code), params: bad
    assert_response :unprocessable_entity
    post apply_cv_path(job.public_code, secret), params: { lamaran: { cv: Rack::Test::UploadedFile.new(StringIO.new("MZ\x90\x00binary"), "application/pdf", original_filename: "cv.pdf") } }
    assert_response :unprocessable_entity
    assert draft.reload.cv.attached?, "the earlier good CV is kept when a bad one is refused"
    assert_equal PortalFactory::PDF_BYTES, draft.cv.download
  end

  test "the step-1 rate limit refuses the burst with 429 and opens no draft past it" do
    Rails.cache.clear
    job = three_step_job!
    limit = Glassbox::Settings::RATE_LIMITS[:lamar_per_ip][:to]
    env = { "REMOTE_ADDR" => "10.77.0.1" }
    params = three_step_details(job)
    params[:lamaran][:email] = "bad"
    limit.times { post apply_start_path(job.public_code), params:, env: }
    assert_response :unprocessable_entity
    good = three_step_details(job)
    assert_no_difference -> { ApplicationDraft.count } do
      post apply_start_path(job.public_code), params: good, env:
    end
    assert_response :too_many_requests
    assert_difference -> { ApplicationDraft.count }, 1, "control: another address is not limited" do
      post apply_start_path(job.public_code), params: good, env: { "REMOTE_ADDR" => "10.77.0.2" }
    end
  ensure
    Rails.cache.clear
  end
end
