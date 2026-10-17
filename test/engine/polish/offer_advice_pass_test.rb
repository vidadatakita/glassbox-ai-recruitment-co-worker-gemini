require "test_helper"

# Independent test pass (17 Oct 2026) on Progression::OfferAdvice, Staff::OffersController#advice and the
# Job offer card. Extends test/services/offer_advice_test.rb, which already proves the vacancy's salary
# band, the applicant's e-mail and phone never reach the AI. Added here:
#   - the AGREED salary (SalaryAgreement.agreed_amount, a figure the band test does not plant) and the
#     applicant's NAME, in both the AI content and the approver summary;
#   - the HTTP refusal for the HR Manager on the HTML and JSON paths, with the AI client never built;
#   - an AI failure is shown to the operator (HTML alert, JSON 422 with the message);
#   - the AI form is not nested in the upload form, checked on the RAW response text. Nokogiri repairs a
#     nested <form> while parsing (it makes the two siblings), so a parsed "form form" query cannot see nesting
#     (pinned by the first test below).
class PolishOfferAdvicePassTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory

  PLANTED_AMOUNT = 7_500_000
  AMOUNT_SHAPES = ["7500000", "7.500.000", "7,500,000", "7500"].freeze

  Fake = Struct.new(:text, :seen, :error) do
    def generate(system:, schema:, content:)
      self.seen = [system, content].join("\n")
      raise error if error

      Screening::AiClient::Reply.new(model: "test-model", text:, input_tokens: 1, output_tokens: 1)
    end
  end

  setup do
    @job = technical_test_job(open_gate: false)
    @application, @status_token = applicant!(@job, name: "Larasati Kusumawardani", email: "larasati.k@contoh.example")
    @candidate = @application.candidate
    @hr = staff_user("hr_pic")
    @manager = staff_user("reviewer")
    SalaryAgreement.create!(job_application: @application, agreed_amount: PLANTED_AMOUNT, outside_band: false,
                            decided_by_id: @manager.id, created_at: Time.current)
  end

  def secrets = [@candidate.name, @candidate.email, @candidate.phone, *AMOUNT_SHAPES].compact.reject(&:empty?)

  test "the parser repairs a nested form, so a parsed 'form form' query can never fail" do
    nested = "<form id='outer'><input name='a'><form id='inner'><input name='b'></form></form>"
    doc = Nokogiri::HTML(nested)
    assert_empty doc.css("form form"), "the parsed tree never holds a form inside a form"
    # Observed with this project's Nokogiri: both forms survive, as siblings; the nesting is gone.
    assert_equal 2, doc.css("form").size
    assert_nil doc.at_css("form#outer form#inner"), "the inner form was moved out of the outer one"
  end

  test "the AI content has no agreed salary, no applicant name, e-mail or phone; it has the vacancy" do
    fake = Fake.new({ day_one_notes: "Bring your ID card. The first week covers the stock count." }.to_json)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, fake) { Progression::OfferAdvice.draft(application: @application, actor: @hr) }
    end
    assert_includes fake.seen, @job.title, "control: the content the fake received is the real content"
    secrets.each { |secret| refute_includes fake.seen, secret.to_s, "#{secret} reached the AI" }
    refute_match(/agreed_amount|salary_min|salary_max/, fake.seen)
  end

  test "the approver summary has no agreed salary, no applicant name, e-mail or phone" do
    text = Progression::OfferAdvice.approver_summary(@application, ScoreMatrix.new(@application))
    assert_includes text, "Position: #{@job.title}.", "control"
    secrets.each { |secret| refute_includes text, secret.to_s, "#{secret} is in the approver summary" }
  end

  test "the HR Manager is refused the draft on both paths and the AI client is never built" do
    sign_in_as @manager
    never = ->(*) { raise "the AI client was built for a refused user" }
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, never) do
        post staff_application_offer_advice_path(@application), params: { commit: "draft" }
        assert_redirected_to staff_jobs_path
        assert_equal "You do not have access to this action.", flash[:alert]

        post staff_application_offer_advice_path(@application), as: :json
        assert_not_equal 200, response.status
        refute_includes response.body.to_s, "day_one_notes"
      end
    end
  end

  test "an AI failure is shown: HTML alert on the offer card, JSON 422 with the message" do
    sign_in_as @hr
    busy = Fake.new(nil, nil, Screening::Errors::Transient.new(:timeout, "invented timeout"))
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, busy) do
        post staff_application_offer_advice_path(@application), params: { commit: "draft" }
        assert_redirected_to staff_application_path(@application, anchor: "job-offer")
        assert_equal "The AI is busy. Try again in a minute.", flash[:alert]
        assert_nil flash[:offer_day_one_draft], "no draft is kept from a failed call"

        post staff_application_offer_advice_path(@application), as: :json
        assert_response :unprocessable_content
        body = JSON.parse(response.body)
        assert_equal false, body["ok"]
        assert_equal "The AI is busy. Try again in a minute.", body["message"]
      end
    end
  end

  test "the offer card: the AI form closes before the upload form opens; named submits keep their value" do
    sign_in_as @hr
    Screening::Config.stub(:enabled?, true) { get staff_application_path(@application) }
    assert_response :success
    raw = response.body
    advice_open = raw.index(%(action="#{staff_application_offer_advice_path(@application)}"))
    upload_open = raw.index(%(action="#{staff_application_offers_path(@application)}"))
    assert advice_open && upload_open, "both forms are on the page"
    advice_close = raw.index("</form>", advice_open)
    assert_operator advice_close, :<, upload_open, "the AI form is still open when the upload form starts"
    card = raw[raw.index('id="job-offer"')..]
    card = card[0, card.index("</form>", card.index(%(action="#{staff_application_offers_path(@application)}"))) + 7]
    assert_equal card.scan("<form").size, card.scan("</form>").size, "every form on the card is closed"

    doc = Nokogiri::HTML(raw)
    offer = doc.at_css("#job-offer")
    offer.css("button[type=submit]").each do |button|
      assert button["name"].present? && button["value"].present?, "submit #{button.text.squish.inspect} has no name/value"
      assert_nil button["disabled"], "a submit is disabled"
    end
  end

  test "the status token never appears on the applicant page" do
    sign_in_as staff_user("superadmin")
    get staff_application_path(@application)
    assert_response :success
    assert @status_token.present?, "fixture: the apply step returned a token"
    refute_includes response.body, @status_token
    refute_includes response.body, CGI.escape(@status_token)
    refute_match(/[?&]token=/, response.body)
  end
end
