require "test_helper"

# D60 slices 3-4 on the rendered pages: the "application sent" page offers the test as the required next step, the start
# page explains the clock before it starts, the case file exists only after start and only with a
# short-lived key, the answer upload, the status timeline in each state, and the house rules
# (no nested form, no disabled submit, no Turbo, wording standard).
class TechnicalTestCandidateTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @t0 = Time.zone.parse("2026-10-05 09:00:00")
    @job = travel_to(@t0) { technical_test_job }
  end

  def apply_through_lamar
    get lamar_path(@job.public_code)
    post lamar_check_path(@job.public_code), params: { knockout: answers_for(@job) }
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post lamar_path(@job.public_code), params: { lamaran: { name: "Dewi Lestari", email: "dewi@uji.example", phone: "081234567890",
                                                             consent: "1", cv: pdf_upload, consent_token: token },
                                                 knockout: answers_for(@job) }
    assert_response :success
    @application = JobApplication.order(:id).last
    @token = response.body[%r{/status/([A-Za-z0-9_\-]+)}, 1]
  end

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit on #{request.path}"
    refute_match(/Terapkan|unggah|berkas|Tautan/i, doc.at("body").text, "wording standard")
    refute_match(/turbo|stimulus/i, doc.css("script").map { |s| s["src"].to_s }.join(" "), "the candidate layout loads no Turbo")
  end

  test "the application-sent page makes the test the required next step, and one email carries the link and the deadline" do
    travel_to(@t0) { apply_through_lamar }
    assert_includes response.body, "Required next step: Technical test (35 minutes)"
    # 2026-10-13: the test is a required next step; no "do it later", one button.
    assert_select "a[href='#{candidate_status_test_path(@token)}']", text: "Start the technical test"
    assert_select "a", text: /do it later|Kerjakan nanti/, count: 0
    assert_select "a.btn", text: /Open the status page|Buka halaman status/, count: 0
    assert_select "h2", text: /Required next step: Technical test/
    assert_includes response.body, "Wednesday, 7 October 2026, 09:00 WIB"
    assert_house_rules
    assert_equal %w[application_received], MailDelivery.where(job_application: @application).pluck(:kind)
    assert_equal 0, TestAttempt.count, "nothing starts from the confirmation page"
  end

  test "the start page says laptop and the duration BEFORE the clock; no case file before start" do
    travel_to(@t0) { apply_through_lamar }
    travel_to(@t0 + 1.hour) { get candidate_status_test_path(@token) }
    assert_response :success
    assert_includes response.body, "laptop or desktop computer"
    assert_includes response.body, "35 minutes"
    assert_select "form[action='#{candidate_status_test_start_path(@token)}'] button", text: "Start test"
    refute_includes response.body, "/case-file", "the case file link exists only after start"
    assert_house_rules

    travel_to(@t0 + 1.hour) { get candidate_status_test_case_file_path(@token) }
    assert_response :not_found
  end

  test "start, refresh keeps due_at, case file needs the page's key, answer upload, then sent" do
    travel_to(@t0) { apply_through_lamar }
    travel_to(@t0 + 1.hour) { post candidate_status_test_start_path(@token) }
    assert_redirected_to candidate_status_test_path(@token)
    attempt = TestAttempt.last
    assert_equal @t0 + 1.hour + 35.minutes, attempt.due_at

    travel_to(@t0 + 1.hour + 10.minutes) do
      post candidate_status_test_start_path(@token) # a replayed start
      get candidate_status_test_path(@token)
    end
    assert_equal attempt.due_at, TestAttempt.sole.due_at
    assert_select "[data-due-at='#{attempt.due_at.iso8601}']"
    assert_includes response.body, "25 minutes"
    assert_select "input[type=file][name=jawaban][accept='.xlsx']"
    assert_house_rules
    link = Nokogiri::HTML(response.body).at("a:contains('Download the case study file')")["href"]

    travel_to(@t0 + 1.hour + 11.minutes) { get link }
    assert_response :success
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert response.body.b.start_with?("PK"), "the case xlsx itself"

    travel_to(@t0 + 1.hour + 11.minutes) { get candidate_status_test_case_file_path(@token, k: "palsu") }
    assert_response :not_found
    travel_to(@t0 + 1.hour + 21.minutes) { get link }
    assert_response :not_found, "the key lives 10 minutes"

    travel_to(@t0 + 1.hour + 30.minutes) { post candidate_status_test_answer_path(@token), params: { jawaban: answer_file } }
    assert_redirected_to candidate_status_test_path(@token)
    follow_redirect!
    assert_includes response.body, "Answer sent"
    assert_equal %w[application_received test_receipt], MailDelivery.where(job_application: @application).order(:id).pluck(:kind)
  end

  test "an answer after due_at + grace is refused on screen and the page says Not taken" do
    travel_to(@t0) { apply_through_lamar }
    travel_to(@t0 + 1.hour) { post candidate_status_test_start_path(@token) }
    due = TestAttempt.last.due_at
    travel_to(due + 121.seconds) { post candidate_status_test_answer_path(@token), params: { jawaban: answer_file } }
    follow_redirect!
    assert_includes response.body, "The technical test time is up"
    assert_includes response.body, "Not taken"
    assert_equal "no_show", s2_of(@application).reload.attendance, "the page load recorded the no-show"
  end

  test "status page timeline: Not started with the deadline, In progress, Answer sent, Not taken" do
    travel_to(@t0) { apply_through_lamar }
    travel_to(@t0 + 1.hour) { get candidate_status_path(@token) }
    assert_includes response.body, "Not started, start by 7 October 2026 at 09:00 WIB"
    assert_select "a[href='#{candidate_status_test_path(@token)}']", text: "Take the technical test"
    assert_includes response.body, "CV screening and technical test"
    refute_includes response.body, "Tes kerja"
    assert_house_rules

    travel_to(@t0 + 2.hours) { post candidate_status_test_start_path(@token) }
    travel_to(@t0 + 2.hours + 5.minutes) { get candidate_status_path(@token) }
    assert_includes response.body, "In progress, 30 minutes left (ends 11:35 WIB)"

    travel_to(@t0 + 2.hours + 10.minutes) { post candidate_status_test_answer_path(@token), params: { jawaban: answer_file } }
    travel_to(@t0 + 3.hours) { get candidate_status_path(@token) }
    assert_includes response.body, "Answer sent Monday, 5 October 2026, 11:10 WIB"
    refute_includes response.body, "not passed", "no gate outcome while the gate is open (D38 Q6a)"
    assert_includes response.body, "CV screening and technical test · The result appears once this stage is complete"
    refute_includes response.body, "Your selection process is complete", "the gate is still open: the next line must say so"
  end

  test "a missed test reads Not taken; the gate outcome with its reason appears only after close" do
    travel_to(@t0) { apply_through_lamar }
    travel_to(@t0 + 49.hours) { get candidate_status_path(@token) }
    assert_includes response.body, "Not taken"
    refute_includes response.body, TechnicalTests::GateOutcome::TEST_NO_SHOW
    s1 = s1_of(@application)
    travel_to(@t0 + 49.hours) do
      s1.update!(attendance: "attended")
      add_score(s1, 80)
      decide!(s1, outcome: "pass")
      Gates::Close.call(stage: s1.stage)
      get candidate_status_path(@token)
    end
    assert_includes response.body, "CV screening and technical test: not passed"
    assert_includes response.body, TechnicalTests::GateOutcome::TEST_NO_SHOW
    refute_match(/\b80\b/, Nokogiri::HTML(response.body).at("main").text, "no score on the candidate page")
  end

  test "start and upload are rate-limited per status link" do
    travel_to(@t0) { apply_through_lamar }
    limit = Glassbox::Settings::RATE_LIMITS[:test_start_per_link][:to]
    travel_to(@t0 + 1.hour) do
      limit.times { post candidate_status_test_start_path(@token) }
      post candidate_status_test_start_path(@token)
    end
    follow_redirect!
    assert_includes response.body, "Too many attempts"
  end

  test "a non-gated job has no technical test page and no test entry on the application-sent page" do
    job = portal_job
    open_portal(job)
    _application, token = submit!(job, email: "tanpa.tes@uji.example")
    get candidate_status_test_path(token)
    assert_response :not_found
    get candidate_status_path(token)
    refute_includes response.body, "Take the technical test"
  end
end
