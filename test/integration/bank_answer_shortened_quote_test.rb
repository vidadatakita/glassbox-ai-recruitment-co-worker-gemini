require "test_helper"

# ApplicationDrafts::AiRate: a quote the AI shortened with an ellipsis counts as verified when every
# excerpt is in the answer; an invented excerpt still fails (17 Oct 2026 sample run: strong answers
# were sent to a person only because the quote ended in "...").
class BankAnswerShortenedQuoteTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include BankFlowHelpers

  QuoteClient = Struct.new(:quote) do
    def generate(system:, schema:, content:)
      Screening::AiClient::Reply.new(model: "uji-model", text: { quote:, reason: "Meets anchor 3.", rating: 3 }.to_json,
                                     input_tokens: 5, output_tokens: 7)
    end
  end

  def rate_with(draft, quote)
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, ->(*, **) { QuoteClient.new(quote) }) { ApplicationDrafts::AiRate.call(draft) }
    end
    draft.answers.reload.select { |a| a.bank_question.written? && a.answer_text.present? }
  end

  test "a shortened quote is verified; an invented excerpt is not" do
    # The helper's written answers read "My plan for case <n> is to check and record."
    shortened = rate_with(applicant!("short@uji.example", mc_right: 1), "My plan for case... check and record.")
    assert shortened.any?
    assert shortened.all?(&:ai_quote_verified), "a verbatim quote cut with an ellipsis was refused"

    invented = rate_with(applicant!("invent@uji.example", mc_right: 1), "My plan for case … and fire the vendor")
    assert invented.any?
    assert invented.none?(&:ai_quote_verified), "an invented excerpt passed"
  end
end
