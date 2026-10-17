# Shared walk for the independent test pass over competency test scoring, slice C (17 Oct 2026).
# Copied from test/integration/bank_scoring_test.rb (not required from it) so these files stand alone,
# with three additions: the applicant's name and written answers are chosen per test, the fake AI
# client records every request it receives (so a test asserts on what was SENT, not on what the
# service meant to send), and its reply can be set per call. Every name and address is invented.
module BankScoringPassHelper
  include TechnicalTestFactory

  # Records each outgoing request. `replies` is an array (one per call, the last repeats) of either a
  # Hash (sent as JSON), a String (sent as the raw reply text) or an Exception (raised).
  class CapturingClient
    attr_reader :contents, :systems

    def initialize(*replies)
      @replies = replies
      @contents = []
      @systems = []
    end

    def generate(system:, schema:, content:)
      @systems << system
      @contents << content
      reply = @replies[[@contents.size - 1, @replies.size - 1].min]
      raise reply if reply.is_a?(Exception)

      answer = content[%r{<answer>\n(.*)\n</answer>}m, 1].to_s
      text = reply.is_a?(String) ? reply : { quote: answer.split.first(3).join(" "), reason: "Meets anchor 3." }.merge(reply).to_json
      Screening::AiClient::Reply.new(model: "pass-model", text:, input_tokens: 5, output_tokens: 7)
    end
  end

  def setup_bank!
    @job = technical_test_job
    @consultant = staff_user("consultant")
    @manager = staff_user("reviewer")
    activity, competency = @job.activities.first, @job.competencies.first
    add = ->(params) { assert TestCases::SaveBank.call(job: @job, actor: @consultant, action: "add", params:).ok? }
    10.times { |i| add.call(section: "technical", kind: "multiple_choice", link_id: "a:#{activity.id}", prompt: "T#{i}", options: { "0" => "right", "1" => "wrong" }, correct: "0") }
    6.times { |i| add.call(section: "role", kind: "written", link_id: "c:#{competency.id}", prompt: "W#{i}", anchor_1: "a", anchor_3: "b", anchor_5: "c") }
    bank = QuestionBank.latest_for(@job)
    TestCases::BankDecision.call(bank:, actor: @consultant, action: "submit")
    TestCases::BankDecision.call(bank: bank.reload, actor: @manager, action: "approve")
  end

  def pass_pdf = Rack::Test::UploadedFile.new(StringIO.new(PortalFactory::PDF_BYTES), "application/pdf", original_filename: "cv.pdf")

  # One applicant through the three-step form. mc_right of the multiple-choice answers are correct;
  # `written` gives the text of the n-th written answer (nil or "" leaves it unanswered).
  def pass_applicant!(email, mc_right:, name: "Pass #{email}", phone: "081234567890", written: ->(i) { "My plan for case #{i} is to check and record." })
    # The apply form is rate-limited per IP (memory cache in test); one test sends several applicants
    # from the same address, so the counter is reset per applicant. Without it runs flake with 429.
    Rails.cache.clear
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name:, email:, phone:, consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    secret = response.location[%r{/d/([^/]+)/cv}, 1]
    post apply_cv_path(@job.public_code, secret), params: { lamaran: { cv: pass_pdf } }
    post apply_test_start_path(@job.public_code, secret)
    draft = ApplicationDraft.find_by_secret(@job, secret)
    mcs = draft.questions.select(&:multiple_choice?)
    ws = draft.questions.select(&:written?)
    answers = draft.questions.to_h do |q|
      [q.id, q.multiple_choice? ? (mcs.index(q) < mc_right ? "0" : "1") : written.call(ws.index(q)).to_s]
    end
    post apply_submit_path(@job.public_code, secret), params: { answers: }
    assert_response :success
    draft.reload
  end

  def pass_ai_rate!(draft, client)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, ->(*, **) { client }) { ApplicationDrafts::AiRate.call(draft) }
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

  def written_answers(draft) = draft.answers.reload.select { |a| a.bank_question.written? }
  def s2_records(draft) = TechnicalTests.participation_for(draft.job_application).then { |p| [p.score_entries.count, Decision.where(participation: p).count] }
end
