require "test_helper"

# Three-step application with the competency test (17 Oct 2026), beside the two-step form: a vacancy
# with an approved bank applies here; details + knockout + consent open a draft, the CV is step 2, the
# test step 3 (draw fixed at start, answers saved, deadline kept by the server), Submit makes the
# application through the same checks, scores multiple choice by the answer key, and marks S2 attended.
class ApplyThreeStepTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    @admin = staff_user("consultant") # the vacancy's assigned consultant builds the bank
    @manager = staff_user("reviewer")
    @bank = approved_bank!(@job)
  end

  def approved_bank!(job)
    activity, competency = job.activities.first, job.competencies.first
    save = ->(params) { assert TestCases::SaveBank.call(job:, actor: @admin, action: "add", params:).ok? }
    10.times { |i| save.call(section: "technical", kind: "multiple_choice", link_id: "a:#{activity.id}", prompt: "Technical #{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    5.times { |i| save.call(section: "role", kind: "multiple_choice", link_id: "c:#{competency.id}", prompt: "Role #{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    save.call(section: "role", kind: "written", link_id: "c:#{competency.id}", prompt: "Describe a hard day.", anchor_1: "a", anchor_3: "b", anchor_5: "c")
    bank = QuestionBank.latest_for(job)
    assert TestCases::BankDecision.call(bank:, actor: @admin, action: "submit").ok?
    assert TestCases::BankDecision.call(bank: bank.reload, actor: @manager, action: "approve").ok?
    bank.reload
  end

  def apply_details_params(knockout: "ya")
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    { lamaran: { name: "Rina Wulandari", email: "rina@contoh.example", phone: "081234567890", consent: "1", consent_token: token },
      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, knockout] } }
  end

  def pdf = Rack::Test::UploadedFile.new(StringIO.new(PortalFactory::PDF_BYTES), "application/pdf", original_filename: "cv.pdf")

  test "the two-step address sends a bank vacancy to the three-step form; the old POST is redirected too" do
    get lamar_path(@job.public_code)
    assert_redirected_to apply_start_path(@job.public_code)
    post lamar_check_path(@job.public_code), params: { knockout: {} }
    assert_redirected_to apply_start_path(@job.public_code)
  end

  test "a knockout No in step 1 stores nothing" do
    assert_no_difference -> { ApplicationDraft.count } do
      post apply_start_path(@job.public_code), params: apply_details_params(knockout: "tidak")
    end
    assert_response :success
  end

  test "details, CV, test, submit: one application, MC scored by the key, S2 attended, draft cleared" do
    assert_difference -> { ApplicationDraft.count }, 1 do
      post apply_start_path(@job.public_code), params: apply_details_params
    end
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    assert secret
    assert_no_difference -> { JobApplication.count } do
      post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    end
    assert_redirected_to apply_test_path(@job.public_code, secret)
    get apply_test_path(@job.public_code, secret)
    assert_select "form[action$='/test/start']", 1
    post apply_test_start_path(@job.public_code, secret)
    draft = ApplicationDraft.last
    assert_equal 8, draft.draw.size, "5 technical + 3 role"
    assert_equal 5, draft.questions.count(&:technical?)
    get apply_test_path(@job.public_code, secret)
    assert_select ".apply-question", 8
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"
    assert_empty doc.css("button[disabled]")

    first, second = draft.questions.select(&:multiple_choice?).first(2)
    post apply_answers_path(@job.public_code, secret), params: { answers: { first.id => "0", second.id => "1" } }, xhr: true
    assert_equal 2, response.parsed_body["saved"]
    assert_difference -> { JobApplication.count }, 1 do
      post apply_submit_path(@job.public_code, secret)
    end
    assert_response :success
    draft.reload
    assert draft.submitted?
    assert_nil draft.name, "personal data lives on the application only"
    refute draft.cv.attached?
    assert draft.job_application.cv.attached?
    assert_equal [true, false], [first, second].map { |q| draft.answers.find_by(bank_question: q).correct }
    assert_equal "attended", TechnicalTests.participation_for(draft.job_application).attendance

    get apply_test_path(@job.public_code, secret)
    assert_includes response.body, "already been sent"
  end

  # The three-step form hands over to the AI interview exactly like the two-step form: with the switch
  # on, Submit goes straight to the chat; with it off (control), the "sent" page as before.
  def submit_three_step!
    post apply_start_path(@job.public_code), params: apply_details_params
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    post apply_test_start_path(@job.public_code, secret)
    assert_difference -> { JobApplication.count }, 1 do
      post apply_submit_path(@job.public_code, secret)
    end
    JobApplication.order(:id).last
  end

  test "AI interview on: Submit goes straight to the chat" do
    switch_ai_interview_on(actor: staff_user("admin"))
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:review_before_ai?, false) do
        application = submit_three_step!
        assert application.interview&.open?, "an interview is created for the application"
        assert_response :redirect
        assert_match %r{/status/[^/]+/interview}, response.location
      end
    end
  end

  test "control: AI interview off, Submit shows the sent page" do
    Screening::Config.stub(:enabled?, true) do
      submit_three_step!
      assert_response :success
      assert_nil JobApplication.order(:id).last.interview
    end
  end

  test "the server keeps the deadline: a late answer is refused, Submit still sends the saved ones" do
    post apply_start_path(@job.public_code), params: apply_details_params
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    post apply_test_start_path(@job.public_code, secret)
    draft = ApplicationDraft.last
    q = draft.questions.first
    travel draft.time_limit_minutes.minutes + 3.minutes do
      post apply_answers_path(@job.public_code, secret), params: { answers: { q.id => "0" } }, xhr: true
      assert_response :unprocessable_entity
      assert_equal 0, draft.answers.count
      assert_difference -> { JobApplication.count }, 1 do
        post apply_submit_path(@job.public_code, secret)
      end
    end
  end

  test "a wrong secret is an invalid link" do
    get apply_cv_path(@job.public_code, "not-a-real-secret")
    assert_response :not_found
  end
end
