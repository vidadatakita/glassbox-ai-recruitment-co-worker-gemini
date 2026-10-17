require "test_helper"

# AI advice in the Job offer section (17 Oct 2026): Gemini drafts the first-day note from the brief only.
# The AI never sees money (FLOW §7) and never sees the applicant; the checklist is computed, not AI.
class OfferAdviceTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  Fake = Struct.new(:text, :seen) do
    def generate(system:, schema:, content:)
      self.seen = content
      Screening::AiClient::Reply.new(model: "test-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = technical_test_job(open_gate: false)
    @job.update_columns(salary_min: 7_123_000, salary_max: 9_876_000)
    @application, = applicant!(@job, name: "Ratri Wulansari")
    @hr = staff_user("hr_pic")
  end

  def draft(fake, actor: @hr)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake) { Progression::OfferAdvice.draft(application: @application, actor:) }
    end
  end

  test "the draft comes from the brief: no salary figure, no applicant name, email or phone reaches the AI" do
    fake = Fake.new({ day_one_notes: "Bring your ID. Your first week covers the monthly close." }.to_json)
    assert_equal "Bring your ID. Your first week covers the monthly close.", draft(fake)
    assert_includes fake.seen, @job.title
    candidate = @application.candidate
    [candidate.name, candidate.email, candidate.phone, "7123000", "7.123.000", "9876000", "9.876.000"].each do |secret|
      refute_includes fake.seen, secret.to_s, "#{secret} was sent to the AI"
    end
    refute_match(/salary|gaji/i, fake.seen)
  end

  test "refusals: an HR Manager, the AI off, an empty or broken reply" do
    assert_raises(Progression::OfferAdvice::Refused) { draft(Fake.new({ day_one_notes: "x" }.to_json), actor: staff_user("reviewer")) }
    assert_raises(Progression::OfferAdvice::Refused) do
      Screening::Config.stub(:enabled?, false) { Progression::OfferAdvice.draft(application: @application, actor: @hr) }
    end
    assert_raises(Progression::OfferAdvice::Refused) { draft(Fake.new({ day_one_notes: "  " }.to_json)) }
    assert_raises(Progression::OfferAdvice::Refused) { draft(Fake.new("not json")) }
  end

  test "the screen: the AI form is its own form (never nested), and the JSON reply fills the first-day field" do
    sign_in_as @hr
    Screening::Config.stub(:enabled?, true) do
      get staff_application_path(@application)
      doc = Nokogiri::HTML(response.body)
      offer = doc.at_css("#job-offer")
      assert_operator offer.css("form").size, :>=, 2, "the AI advice form and the upload form are both on the page"
      # Nokogiri un-nests forms while parsing, so the raw tags are walked instead.
      depth = 0
      response.body.scan(%r{<form\b|</form>}).each { |tag| depth += tag == "</form>" ? -1 : 1; assert_operator depth, :<=, 1, "a form inside a form" }
      assert offer.at_css("form[action='#{staff_application_offer_advice_path(@application)}']"), "the AI advice form"
      fake = Fake.new({ day_one_notes: "Your first day starts with the team." }.to_json)
      Screening::Config.stub(:client, fake) do
        post staff_application_offer_advice_path(@application), as: :json
      end
      body = JSON.parse(response.body)
      assert body["ok"]
      assert_equal "Your first day starts with the team.", body.dig("fields", "offer[day_one_notes]")
    end
  end

  test "the checklist says what is still missing, computed from the record" do
    labels = Progression::OfferAdvice.checklist(@application).to_h { |c| [c.label, c.ok] }
    assert_equal false, labels["Salary agreed by the HR Manager or Superadmin"]
    assert_equal true, labels["Consent still in force"]
  end

  test "the approver summary: stage results and the recorded advice, never a salary figure or contact detail" do
    matrix = ScoreMatrix.new(@application)
    text = Progression::OfferAdvice.approver_summary(@application, matrix)
    assert_includes text, "Position: #{@job.title}."
    candidate = @application.candidate
    [candidate.email, candidate.phone, "7123000", "7.123.000", "9.876.000"].each { |secret| refute_includes text, secret.to_s }
    assert_match(/agreed separately/, text)
  end
end
