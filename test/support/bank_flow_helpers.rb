# Shared walk for the competency-test scoring tests: a vacancy with an approved bank (10 technical
# multiple choice + 6 role written questions), applicants through the three-step form, AI ratings from a
# fake client, S1 passed. Used by bank_scoring_test.rb and bank_result_downstream_test.rb.
module BankFlowHelpers
  extend ActiveSupport::Concern
  # The including test also includes TechnicalTestFactory (support files load alphabetically, so it is not
  # included here).

  FakeClient = Struct.new(:rating) do
    def generate(system:, schema:, content:)
      answer = content[%r{<answer>\n(.*)\n</answer>}m, 1].to_s
      Screening::AiClient::Reply.new(model: "uji-model", text: { quote: answer.split.first(3).join(" "), reason: "Meets anchor 3.", rating: }.to_json,
                                     input_tokens: 5, output_tokens: 7)
    end
  end

  included do
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
end
