require "test_helper"
require_relative "run2_support"

# Test engine 07 run 2 on rendered pages: the candidate test pages (clock tampering, case-file key,
# upload), the staff scoring page (names, downloads, roles), the F-01 identity fix on every staff
# page that names a candidate, the F-02 approve form, wording and the house hard rules.
class Engine07Run2ScreensTest < ActionDispatch::IntegrationTest
  include Run2Support

  FORBIDDEN = /Terapkan|diterapkan|unggah|berkas|Tautan|Tatap muka/i

  setup do
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    @t0 = Time.zone.parse("2026-10-06 08:00:00")
    @job = travel_to(@t0) { r2_job }
    @appl, @token = travel_to(@t0) { r2_apply(@job, name: "Rina Pratiwi Rdua") }
  end

  def house_rules(label, candidate: false)
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/i).size, doc.css("form").size, "nested form on #{label}"
    doc.css("form").each { |f| assert_empty f.css("form"), "form in form on #{label}" }
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with], [data-turbo-submits-with]"), "disabled submit on #{label}"
    refute_match(/fa-eye\b/, response.body, label)
    assert_no_match FORBIDDEN, doc.at("body").text, "wording on #{label}"
    return unless candidate

    scripts = doc.css("script").map { |s| "#{s['src']} #{s.text[0, 400]}" }.join(" ")
    refute_match(/turbo|stimulus/i, scripts, "candidate layout loads Turbo/Stimulus on #{label}")
    refute_match(/importmap/i, response.body, "importmap (Turbo/Stimulus) on candidate #{label}")
  end

  def case_link = Nokogiri::HTML(response.body).css("a[href*='case-file']").first&.[]("href")

  # ---- candidate: clock ---------------------------------------------------------------------------
  test "client-sent times are ignored; a replayed Start test keeps the first due_at" do
    travel_to(@t0 + 1.hour) do
      get candidate_status_test_path(@token)
      house_rules("start page", candidate: true)
      post candidate_status_test_start_path(@token), params: { started_at: (@t0 - 5.days).iso8601, due_at: (@t0 + 9.days).iso8601,
                                                                 test_attempt: { due_at: (@t0 + 9.days).iso8601 }, time_limit_minutes: 600 }
    end
    a = r2_attempt(@appl)
    assert_equal [@t0 + 1.hour, @t0 + 1.hour + 35.minutes], [a.started_at, a.due_at]
    travel_to(@t0 + 1.hour + 20.minutes) { post candidate_status_test_start_path(@token) }
    assert_equal 1, TestAttempt.where(participation: r2_s2(@appl)).count
    assert_equal @t0 + 1.hour + 35.minutes, a.reload.due_at
    travel_to(@t0 + 1.hour + 21.minutes) { get candidate_status_test_path(@token) }
    house_rules("running page", candidate: true)
    assert_select "[data-due-at]"
  end

  test "start after 48 h is refused on screen and nothing is written" do
    travel_to(@t0 + 48.hours + 1.second) do
      post candidate_status_test_start_path(@token)
      follow_redirect!
    end
    assert_nil r2_attempt(@appl)
    assert_includes response.body, "Not taken"
    house_rules("expired page", candidate: true)
  end

  # ---- candidate: case-file key -----------------------------------------------------------------
  test "case file: no key, a guessed key, another candidate's key, an expired key all refused; the minted key works" do
    other, other_token = travel_to(@t0) { r2_apply(@job, name: "Sinta Rdua") }
    travel_to(@t0 + 1.hour) { get candidate_status_test_path(@token) }
    refute case_link, "case-file link before start"
    travel_to(@t0 + 1.hour) { get candidate_status_test_case_file_path(@token) }
    assert_includes [404, 410], response.status
    travel_to(@t0 + 1.hour) do
      post candidate_status_test_start_path(other_token)
      get candidate_status_test_path(other_token)
    end
    other_link = case_link
    other_key = Rack::Utils.parse_query(URI(other_link).query)["k"]
    travel_to(@t0 + 1.hour + 1.minute) do
      post candidate_status_test_start_path(@token)
      get candidate_status_test_path(@token)
    end
    mine = case_link
    key = Rack::Utils.parse_query(URI(mine).query)["k"]
    { "guessed" => "abc", "other candidate's key" => other_key, "tampered" => key.reverse }.each do |label, k|
      travel_to(@t0 + 1.hour + 2.minutes) { get candidate_status_test_case_file_path(@token, k:) }
      refute_equal 200, response.status, label
    end
    travel_to(@t0 + 1.hour + 2.minutes) { get candidate_status_test_case_file_path(other_token, k: key) }
    refute_equal 200, response.status, "my key under the other candidate's link"
    travel_to(@t0 + 1.hour + 1.minute + 10.minutes - 1.second) { get mine }
    assert_equal 200, response.status, "key inside its 10 minutes"
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    travel_to(@t0 + 1.hour + 1.minute + 10.minutes + 1.second) { get mine }
    refute_equal 200, response.status, "key after 10 minutes"
    assert other
  end

  # The key is checked against the attempt and the link, not against the test's state: after the
  # answer was sent (or the time ran out) a key minted while running still downloads the case for the
  # rest of its 10 minutes. Recorded as an observation (low): the candidate already had the file.
  test "PROBE: a key minted while running still downloads after the answer is sent (within its 10 minutes)" do
    travel_to(@t0 + 1.hour) do
      post candidate_status_test_start_path(@token)
      get candidate_status_test_path(@token)
    end
    link = case_link
    travel_to(@t0 + 1.hour + 2.minutes) { TechnicalTests::SubmitAnswer.call(application: @appl, file: e7_upload(e7_xlsx, "j.xlsx")) }
    travel_to(@t0 + 1.hour + 3.minutes) { get link }
    assert_equal 200, response.status
  end

  # ---- candidate: upload ------------------------------------------------------------------------
  test "upload on screen: double submit keeps the first answer; one receipt; late by 1 s refused with a sentence" do
    late, late_token = travel_to(@t0) { r2_apply(@job, name: "Telat Rdua") }
    travel_to(@t0 + 1.hour) do
      post candidate_status_test_start_path(@token)
      post candidate_status_test_start_path(late_token)
    end
    first = e7_xlsx([["pertama"]])
    travel_to(@t0 + 1.hour + 10.minutes) do
      post candidate_status_test_answer_path(@token), params: { jawaban: e7_upload(first, "j.xlsx") }
      post candidate_status_test_answer_path(@token), params: { jawaban: e7_upload(e7_xlsx([["kedua"]]), "j.xlsx") }
      follow_redirect!
    end
    assert_includes response.body, "only once"
    assert_equal Digest::SHA256.hexdigest(first), r2_attempt(@appl).answer_sha256
    assert_equal 1, MailDelivery.where(job_application: @appl, kind: "test_receipt").count
    house_rules("sent page", candidate: true)
    a = r2_attempt(late)
    travel_to(a.due_at + 121.seconds) do
      post candidate_status_test_answer_path(late_token), params: { jawaban: e7_upload(e7_xlsx, "j.xlsx") }
      follow_redirect!
    end
    assert_nil a.reload.answered_at
    assert_includes response.body, "Not taken"
    assert_equal "no_show", r2_s2(late).attendance, "lazy expiry on the page load"
  end

  # ---- candidate status page ------------------------------------------------------------------
  test "status page after scoring and after close: no score, no threshold, no ranking, no AI" do
    attempt = travel_to(@t0 + 1.hour) { r2_s1_decide!(@appl, "pass"); r2_answer(@appl) }
    TechnicalTests::ScoreAnswer.call(attempt:, reviewer: r2_reviewer, ratings: r2_ratings(attempt, [3, 4]), note: "Cukup")
    [:open, :closed].each do |phase|
      Gates::Close.call(stage: @job.stages.find_by!(code: "S1")) if phase == :closed
      get candidate_status_path(@token)
      assert_response :success
      text = Nokogiri::HTML(response.body).at("body").text
      # control: the page really shows the test and the gate, so the no-leak check reads a filled page
      assert_includes text, "Technical test", phase.to_s
      assert_includes text, (phase == :open ? "Answer sent" : "CV screening and technical test: passed"), phase.to_s
      assert_no_match(/\b60[.,]0\b|\bskor\b|\bambang\b|\bperingkat\b|\branking\b|\bscore\b|\bthreshold\b/i, text, phase.to_s)
      assert_no_match(/\bAI\b/, text, phase.to_s)
      house_rules("status #{phase}", candidate: true)
    end
  end

  # ---- staff: scoring page ----------------------------------------------------------------------
  test "scoring page: HR PIC and owner see Candidate NN, no download link, cannot post a score; reviewer sees the name" do
    attempt = travel_to(@t0 + 1.hour) { r2_answer(@appl) }
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_scorings_path(@job)
      assert_response :success
      refute_includes response.body, "Rina Pratiwi Rdua", "#{role} sees the name"
      assert_match(/Candidate \d\d/, response.body)
      assert_empty css_select("a[href*='/answer']"), "#{role} has an answer download link"
      house_rules("scoring #{role}")
      post staff_test_attempt_score_path(attempt), params: { ratings: r2_ratings(attempt, [5, 5]), note: "x" }
      assert_equal 0, r2_s2(@appl).score_entries.count, "#{role} scored"
    end
    sign_in_as r2_reviewer
    get staff_job_test_scorings_path(@job)
    assert_includes response.body, "Rina Pratiwi Rdua"
    house_rules("scoring reviewer")
  end

  test "answer download: reviewer and consultant with their own key; HR PIC with a reviewer's key refused; key expires in 5 min" do
    attempt = travel_to(@t0 + 1.hour) { r2_answer(@appl) }
    sign_in_as r2_reviewer
    get staff_job_test_scorings_path(@job)
    link = css_select("a[href*='/answer']").first["href"]
    get link
    assert_response :success
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    %w[hr_pic owner admin].each do |role|
      sign_in_as staff_user(role)
      get link
      refute_equal 200, response.status, "#{role} downloaded an answer with a reviewer's key"
    end
    sign_in_as staff_user("consultant")
    get link
    refute_equal 200, response.status, "the consultant used the reviewer's key"
    get staff_job_test_scorings_path(@job)
    own = css_select("a[href*='/answer']").first&.[]("href")
    assert own, "the consultant has no download link"
    get own
    assert_response :success
    sign_in_as r2_reviewer
    get staff_job_test_scorings_path(@job)
    fresh = css_select("a[href*='/answer']").first["href"]
    travel_to(Time.current + 5.minutes + 1.second) { get fresh }
    refute_equal 200, response.status, "answer key after 5 minutes"
    assert attempt
  end

  # ---- F-01: identity on every staff page that names a candidate --------------------------------
  test "F-01 fix: HR PIC and owner see no name on the job page, the applicant page, its CV, the scoring page until the gate closes" do
    attempt = travel_to(@t0 + 1.hour) { r2_s1_decide!(@appl, "pass"); r2_answer(@appl) }
    pages = -> { [staff_job_path(@job), staff_application_path(@appl), staff_job_test_scorings_path(@job)] }
    %w[hr_pic owner].each do |role|
      sign_in_as staff_user(role)
      pages.().each do |path|
        get path
        assert_response :success
        refute_includes response.body, "Rina Pratiwi Rdua", "#{role} sees the name on #{path}"
        refute_includes response.body, @appl.candidate.email, "#{role} sees the email on #{path}"
        refute_includes response.body, @appl.candidate.phone, "#{role} sees the phone on #{path}"
      end
    end
    TechnicalTests::ScoreAnswer.call(attempt:, reviewer: r2_reviewer, ratings: r2_ratings(attempt, [4, 4]), note: "Baik")
    Gates::Close.call(stage: @job.stages.find_by!(code: "S1"))
    sign_in_as staff_user("hr_pic")
    get staff_application_path(@appl)
    assert_includes response.body, "Rina Pratiwi Rdua", "control: names after the gate closed"
  end

  test "F-01 fix: the number is the same person on the gate box and the applicant table" do
    travel_to(@t0) { r2_apply(@job, name: "Kedua Rdua") }
    sign_in_as staff_user("hr_pic")
    get staff_job_path(@job)
    gate = css_select("#gerbang-seleksi tbody tr").to_h do |tr|
      [tr.css("td").first.text.strip, tr.css("a").first["href"]]
    end
    refute_empty gate
    table = css_select("table tbody tr").reject { |tr| tr.ancestors("#gerbang-seleksi").any? }.filter_map do |tr|
      link = tr.css("a[href*='/applications/']").first
      link && [link["href"], tr.css("td").first.text.strip]
    end.to_h
    assert_equal gate.size, (gate.values & table.keys).size, "fixture: every gate row has an applicant-table row"
    gate.each do |label, href|
      assert_match(/\ACandidate \d\d\z/, label)
      assert_equal label, table[href], "the gate box and the applicant table number #{href} differently"
    end
  end

  # A real SMTP refusal names the recipient ("550 5.1.1 <a@b>: Recipient address rejected", Postfix).
  # MailDelivery.deliver! stores e.message, and Antrean Kerja prints it beside the numbered label.
  test "FINDING: HR PIC reads the candidate's email in Antrean Kerja through a failed notice's error text" do
    email = @appl.candidate.email
    MailDelivery.create!(job_application: @appl, kind: "test_receipt", status: "failed", error_class: "Net::SMTPFatalError",
                         error_message: "550 5.1.1 <#{email}>: Recipient address rejected: User unknown in virtual mailbox table")
    sign_in_as staff_user("hr_pic")
    get staff_work_queue_path
    assert_response :success
    assert_match(/Candidate \d\d/, response.body, "fixture: the row is numbered for HR PIC")
    refute_includes response.body, email, "HR PIC sees #{email} in Antrean Kerja while the gate is open"
  end

  # ---- F-02 on screen -----------------------------------------------------------------------------
  test "F-02 fix on screen: the approve form carries the digest; a stale click is refused with a sentence; a fresh one approves" do
    job = e7_brief
    e7_save(job, instructions: "Versi yang dibaca HR")
    sign_in_as staff_user("hr_pic")
    get staff_job_test_case_step_path(job)
    form = css_select("form.test-case-approve").first
    fields = form.css("input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    assert fields["content_digest"].present?
    e7_save(job, instructions: "Diganti")
    post form["action"], params: fields
    assert_response :unprocessable_content
    assert_includes response.body, "has changed since you opened it"
    house_rules("approve refused")
    post form["action"], params: fields.except("content_digest")
    refute TechnicalTestCase.latest_for(job).approved?, "a POST without the digest approved"
    get staff_job_test_case_step_path(job)
    form = css_select("form.test-case-approve").first
    post form["action"], params: form.css("input[type=hidden]").to_h { |i| [i["name"], i["value"]] }
    assert TechnicalTestCase.latest_for(job).approved?
  end
end
