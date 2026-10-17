require "test_helper"

# Written-answer quotes (ApplicationDrafts::AiRate): one string that may hold excerpts joined or cut
# short with an ellipsis. Every excerpt must be verbatim; the ellipsis is never matched.
class Screening::QuoteCheckExcerptsTest < ActiveSupport::TestCase
  ANSWER = "First I would map the problem with data: lane, hub and carrier. Then I run a root-cause " \
           "session with the hub leads, and track the KPI weekly until it holds.".freeze

  def found?(quote) = Screening::QuoteCheck.excerpts_found?(quote, ANSWER)

  test "a whole verbatim quote is found" do
    assert found?("Then I run a root-cause session with the hub leads")
  end

  test "a quote cut short or joined with an ellipsis is found when every excerpt is verbatim" do
    assert found?("First I would map the problem with data: lane, hub and carrier. Then I run a root-cause session..."), "three dots at the end"
    assert found?("First I would map the problem … track the KPI weekly"), "two excerpts joined"
    assert found?("...with the hub leads...")
  end

  test "an invented excerpt fails the whole quote, even beside a real one" do
    refute found?("First I would map the problem … and fire the vendor at once")
    refute found?("First I would map the problem, then fire the vendor")
    refute found?("first i would map the problem"), "case must match"
  end

  test "a quote with no evidence is not found" do
    refute found?("")
    refute found?("...")
    refute found?(nil)
  end

  test "an answer that itself contains three dots still verifies its own quote" do
    assert Screening::QuoteCheck.excerpts_found?("I would wait... then check the data", "Honestly, I would wait... then check the data again.")
  end
end
