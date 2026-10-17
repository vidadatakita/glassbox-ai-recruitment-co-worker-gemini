require "test_helper"

# Competency test scoring (slice C, 17 Oct 2026): the AI rates written answers after Submit; the HR
# Manager confirms written answers at or above the vacancy average and records the AI-based result
# below it; the result is the S2 ScoreEntry + Decision.
class BankScoringTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  FakeClient = Struct.new(:rating) do
    def generate(system:, schema:, content:)
      answer = content[%r{<answer>\n(.*)\n</answer>}m, 1].to_s
      Screening::AiClient::Reply.new(model: "uji-model", text: { quote: answer.split.first(3).join(" "), reason: "Meets anchor 3.", rating: }.to_json,
                                     input_tokens: 5, output_tokens: 7)
    end
  end

  setup do
    @job = technical_test_job
    @consultant = staff_user("consultant")
    @manager = staff_user("reviewer")
    activity, competency = @job.activities.first, @job.competencies.first
    add = ->(params) { assert TestCases::SaveBank.call(job: @job, actor: @consultant, action: "add", params:).ok? }
    10.times { |i| add.call(section: "technical", kind: "multiple_choice", link_id: "a:#{activity.id}", prompt: "T#{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    3.times { |i| add.call(section: "role", kind: "written", link_id: "c:#{competency.id}", prompt: "W#{i}", anchor_1: "a", anchor_3: "b", anchor_5: "c") }
    3.times { |i| add.call(section: "role", kind: "written", link_id: "c:#{competency.id}", prompt: "W#{i + 3}", anchor_1: "a", anchor_3: "b", anchor_5: "c") }
    bank = QuestionBank.latest_for(@job)
    TestCases::BankDecision.call(bank:, actor: @consultant, action: "submit")
    TestCases::BankDecision.call(bank: bank.reload, actor: @manager, action: "approve")
  end

  def pdf = Rack::Test::UploadedFile.new(StringIO.new(PortalFactory::PDF_BYTES), "application/pdf", original_filename: "cv.pdf")

  # One applicant through the three-step form; mc_right of the 5 technical answers correct, every
  # written answer filled. Returns the submitted draft.
  def applicant!(email, mc_right:)
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name: "Uji #{email}", email:, phone: "081234567890", consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pdf } }
    post apply_test_start_path(@job.public_code, secret)
    draft = ApplicationDraft.find_by_secret(@job, secret)
    answers = draft.questions.each_with_index.to_h do |q, i|
      [q.id, q.multiple_choice? ? (draft.questions.select(&:multiple_choice?).index(q) < mc_right ? "0" : "1") : "My plan for case #{i} is to check and record."]
    end
    post apply_submit_path(@job.public_code, secret), params: { answers: }
    assert_response :success
    draft.reload
  end

  def ai_rate!(draft, rating)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, ->(*, **) { FakeClient.new(rating) }) { ApplicationDrafts::AiRate.call(draft) }
    end
  end

  def pass_s1!(draft)
    s1 = s1_of(draft.job_application)
    s1.update!(attendance: "attended") if s1.attendance == "pending"
    ScoreEntry.create!(participation: s1, value: 90, entered_by_id: @manager.id, event_at: Time.current, entered_at: Time.current) unless s1.score_entries.exists?
    return if s1.current_decision

    result = Scoring::Decider.decide(score: 90, threshold: s1.stage.threshold, attendance: :attended)
    Decision.create!(participation: s1, outcome: result.outcome.to_s, basis: result.basis.to_s, reason_code: result.reason_code, decided_at: Time.current)
  end

  test "AI rates written answers; above the average the HR Manager confirms, below it the AI result is recorded" do
    strong = applicant!("strong@uji.example", mc_right: 5)
    weak = applicant!("weak@uji.example", mc_right: 0)
    ai_rate!(strong, 5)
    ai_rate!(weak, 1)
    assert_equal %w[done done], [strong.reload.ai_status, weak.reload.ai_status]
    assert(strong.answers.select { |a| a.bank_question.written? }.all? { |a| a.ai_rating == 5 && a.ai_quote_verified })
    [strong, weak].each { |d| pass_s1!(d) }

    board = ApplicationDrafts::Board.new(@job)
    assert_equal 100.0, ApplicationDrafts::Score.call(strong).value
    assert_equal 0.0, ApplicationDrafts::Score.call(weak).value
    assert_equal 50.0, board.average
    refute board.below_average?(strong)
    assert board.below_average?(weak)

    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    assert_response :success
    assert_select "input[name=mode][value=review]", 1
    assert_select "input[name=mode][value=ai]", 1
    doc = Nokogiri::HTML(response.body)
    assert_equal response.body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"

    post staff_job_bank_scoring_record_path(@job, strong), params: { mode: "ai" }
    assert_response :unprocessable_content, "an applicant at or above the average cannot skip the HR Manager"
    written = strong.answers.select { |a| a.bank_question.written? }
    post staff_job_bank_scoring_record_path(@job, strong), params: { mode: "review", note: "Clear, complete answers.",
                                                                     ratings: written.to_h { |a| [a.id, "4"] } }
    assert_redirected_to staff_job_bank_scorings_path(@job)
    s2 = TechnicalTests.participation_for(strong.job_application)
    assert_in_delta 90.6, s2.score_entries.current.first.value.to_f, 0.05, "(5 MC right x 100 + 3 written rated 4 x 75) / 8 = 90.625"
    assert s2.current_decision
    assert_equal [4], strong.answers.reload.filter_map(&:review_rating).uniq

    post staff_job_bank_scoring_record_path(@job, weak), params: { mode: "ai" }
    assert_redirected_to staff_job_bank_scorings_path(@job)
    weak_s2 = TechnicalTests.participation_for(weak.job_application)
    assert_equal "ai_below_average", weak_s2.score_entries.current.first.ratings["basis"]
    post staff_job_bank_scoring_record_path(@job, weak), params: { mode: "ai" }
    assert_response :unprocessable_content, "recorded once"
  end

  test "the consultant and an HR Admin cannot record; the database refuses the consultant's confirmation" do
    draft = applicant!("one@uji.example", mc_right: 3)
    ai_rate!(draft, 3)
    pass_s1!(draft)
    sign_in_as @consultant
    post staff_job_bank_scoring_record_path(@job, draft), params: { mode: "ai" }
    refute TechnicalTests.participation_for(draft.job_application).current_decision
    answer = draft.answers.find { |a| a.bank_question.written? }
    refused_by_database { answer.update_columns(review_rating: 3, reviewed_by_id: @consultant.id, reviewed_at: Time.current) }
  end

  test "an AI failure is recorded on the draft and shown, never swallowed" do
    draft = applicant!("fail@uji.example", mc_right: 1)
    broken = Object.new
    def broken.generate(**) = raise(Screening::Errors::Transient.new("transient", "timeout"))
    Screening::Config.stub(:enabled?, true) { Screening::Config.stub(:client, ->(*, **) { broken }) { ApplicationDrafts::AiRate.call(draft) } }
    assert_equal "failed", draft.reload.ai_status
    assert_match(/timeout/, draft.ai_error)
    refute ApplicationDrafts::Score.call(draft).complete?
    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    assert_includes response.body, "timeout"
    assert_select "form[action$='/retry-ai']", 1
  end
end
