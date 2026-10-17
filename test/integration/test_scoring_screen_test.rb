require "test_helper"

# D60 slice 5 on the rendered staff screen "Technical test scoring": who sees what (names vs numbers,
# D62 h7), who scores, the answer download (signed, short-lived, attachment, nosniff, scan state
# shown first), and the house form rules.
class TestScoringScreenTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    @application, = applicant!(@job, name: "Dewi Lestari")
    @attempt = answered!(@application)
  end

  def assert_house_rules
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "a form inside a form on #{request.path}"
    assert_empty doc.css("button[disabled], input[type=submit][disabled], [data-disable-with]"), "disabled submit"
    refute_match(/fa-eye\b/, response.body)
    refute_match(/Terapkan|unggah|berkas|Tautan/i, doc.at("body").text, "wording standard")
  end

  # Three-role model (17 Oct 2026): the reviewer is an HR manager, blind before the gate like every
  # non-superadmin role, so the answer is labelled by candidate number.
  test "the reviewer sees the answer, the scan state before the download, the pinned rubric and the 1-5 form" do
    sign_in_as reviewer
    get staff_job_test_scorings_path(@job)
    assert_response :success
    assert_includes response.body, "Candidate 01"
    refute_includes response.body, "Dewi Lestari", "the HR manager must not see the name before the gate (D62 h7)"
    assert_includes response.body, "Not scanned by antivirus"
    @attempt.test_case.criteria.each do |criterion|
      assert_includes response.body, criterion.anchor_5
      assert_select "input[type=radio][name='ratings[#{criterion.id}]']", 5
    end
    assert_select "form[action='#{staff_test_attempt_score_path(@attempt)}'] textarea[name=note][required]"
    assert_house_rules
  end

  test "scoring from the screen writes the decision and moves the answer to Scored" do
    sign_in_as reviewer
    post staff_test_attempt_score_path(@attempt), params: { ratings: ratings_for(@attempt, [5, 5]), note: "Semua selisih ditemukan." }
    assert_redirected_to staff_job_test_scorings_path(@job)
    follow_redirect!
    assert_includes response.body, "Score saved"
    assert_includes response.body, "100,0"
    assert_equal "pass", s2_of(@application).current_decision.outcome
  end

  test "a refused scoring says why on screen and writes nothing" do
    sign_in_as reviewer
    post staff_test_attempt_score_path(@attempt), params: { ratings: ratings_for(@attempt, [5]), note: "x" }
    follow_redirect!
    assert_includes response.body, "Give a rating of 1 to 5"
    assert_empty s2_of(@application).score_entries
  end

  test "the job's consultant reads but cannot score, and the server refuses a forged post" do
    sign_in_as User.find(@job.consultant_id)
    get staff_job_test_scorings_path(@job)
    assert_response :success
    assert_includes response.body, "You are the consultant of this vacancy"
    assert_select "form[action='#{staff_test_attempt_score_path(@attempt)}']", 0
    post staff_test_attempt_score_path(@attempt), params: { ratings: ratings_for(@attempt, [5, 5]), note: "x" }
    assert_empty s2_of(@application).score_entries
  end

  # Three-role model (17 Oct 2026): every non-superadmin person is blind before the gate. The HR
  # managers (old owner and reviewer) download answers; the HR admins (old HR PIC and consultant) do
  # not while the gate is open (old HR PIC rule, SPEC report §2.4).
  test "HR admin and HR manager see candidate numbers only; the HR admin gets no answer download while the gate is open" do
    %w[hr_pic consultant owner reviewer].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_scorings_path(@job)
      assert_response :success
      assert_includes response.body, "Candidate 01"
      refute_includes response.body, "Dewi Lestari", "#{role} must not see the name (D62 h7)"
      if staff_user(role).role == "hr_admin"
        refute_includes response.body, "Download answer", "#{role} downloads while the gate is open"
      else
        assert_includes response.body, "Download answer", "#{role} (HR manager) has no download"
      end
      sign_out
    end
  end

  test "answer download: signed key bound to the user, attachment with nosniff; no key or another user's key refused" do
    sign_in_as reviewer
    get staff_job_test_scorings_path(@job)
    link = Nokogiri::HTML(response.body).at("a:contains('Download answer')")["href"]
    get link
    assert_response :success
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    assert response.body.b.start_with?("PK")

    get staff_test_attempt_answer_path(@attempt)
    assert_response :redirect, "no key, no file"
    sign_out
    sign_in_as User.find(@job.consultant_id)
    get link
    assert_response :redirect, "a key minted for the reviewer does not open for another user"
    travel 6.minutes do
      sign_out
      sign_in_as reviewer
      get link
      assert_response :redirect, "the key lives 5 minutes"
    end
  end

  # Three-role model (17 Oct 2026): no role is refused at the controller any more (owner is an HR
  # manager, admitted by require_role!), so the owner's refusal is now the key check: a key minted for
  # the HR admin does not open for anyone else.
  test "HR admin: no answer download while the gate is open, even with a key minted for HR; another user's key never opens" do
    key = TechnicalTests.answer_key(staff_user("hr_pic"), @attempt)
    sign_in_as staff_user("hr_pic")
    get staff_test_attempt_answer_path(@attempt, k: key)
    assert_redirected_to staff_job_test_scorings_path(@job)
    sign_out
    sign_in_as staff_user("owner")
    get staff_test_attempt_answer_path(@attempt, k: key)
    assert_redirected_to staff_job_test_scorings_path(@job), "a key minted for the HR admin opened for the owner"
  end

  test "HR admin downloads the answer once the gate is closed (SPEC report §2.4), with its own signed key" do
    s1 = s1_of(@application)
    s1.update!(attendance: "attended")
    add_score(s1, 80)
    decide!(s1, outcome: "pass")
    TechnicalTests::ScoreAnswer.call(attempt: @attempt, reviewer: reviewer, ratings: ratings_for(@attempt, [5, 5]), note: "Baik.")
    Gates::Close.call(stage: s1.stage)
    sign_in_as staff_user("hr_pic")
    get staff_job_test_scorings_path(@job)
    link = Nokogiri::HTML(response.body).at("a:contains('Download')")["href"]
    get link
    assert_response :success
    assert_match(/\Aattachment/, response.headers["Content-Disposition"])
    # Gate closed: both HR admins and both HR managers download; superadmin passes every role check
    # (three-role model, 17 Oct 2026), so it downloads too.
    assert_equal [true, true, true, true, true],
                 %w[reviewer consultant hr_pic owner admin].map { |r| TechnicalTests.answer_downloadable_by?(staff_user(r), @job.reload) }
  end

  test "the gate box links to the scoring screen" do
    sign_in_as staff_user("consultant")
    get staff_job_path(@job)
    assert_select "a[href='#{staff_job_test_scorings_path(@job)}']", text: /Technical test scoring/
  end
end
