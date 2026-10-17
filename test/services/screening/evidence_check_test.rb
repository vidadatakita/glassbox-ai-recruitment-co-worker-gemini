require "test_helper"

# Plan task A7 / build item C1: the evidence check (FLOW v2.1 step 7). Every quote the model returns
# is searched verbatim in the CV text; a quote that is not there marks the criterion "unverified",
# the score cannot become a decision by itself, and the CV goes to a reviewer.
#
# End to end through Screening::Run: the Gemini API is stubbed at the HTTP boundary
# (ScreeningFactory::FakeGemini), so the answer below is parsed, checked and stored by the real
# code path, not by a unit under test in isolation.
#
# Load-bearing proof (docs/engineering-notes/C1-evidence-check.md): with the check disabled in
# app/models/screening/quote_check.rb (`normalise(haystack).include?(q)` replaced by `true`, the
# mutant A3 of script/mutation_check_06.rb) the first test goes red. The second test is the control:
# a check that marked EVERYTHING unverified would pass the first test and fail this one.
class Screening::EvidenceCheckTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  # Plausible for the role, grammatical, and NOT in FIXTURE_CV: the kind of quote a model invents.
  PLANTED = "Supervised a warehouse team of 40 people at PT Sentosa for ten years".freeze

  setup do
    @job = screening_job
    @fake = FakeGemini.new
  end

  def screen!(criteria)
    with_ai(@fake) do
      @fake.push(gemini_message(criteria))
      @participation = apply_with_cv!(@job)
      screen_and_release! # a reviewer releases the redacted text first (step 6); then the call
    end
    @participation.screening_results.last
  end

  def should_have_key = rubric_keys(@job).find { |k| Requirement.find(k.delete("R")).tier == "sebaiknya" }

  test "a planted quote that is not in the CV is marked unverified and the CV waits for a reviewer" do
    key = should_have_key
    result = screen!(criteria_for(@job, quotes: { key => PLANTED }))
    refute_nil result, "the run stored no result"

    planted = result.criteria.find { |c| c["key"] == key }
    assert_equal PLANTED, planted["quote"], "the invented quote is stored as the model gave it, so the reviewer sees it"
    assert_equal false, planted["verified"]
    assert_equal 1, result.unverified_count
    # The planted text is nowhere in what the model was given either: it is invented, not merely
    # cut by redaction (a quote that spans a redaction marker is checked against the redacted text).
    refute_includes @fake.bodies.sole, PLANTED

    item = Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == @participation.id }
    refute_nil item, "an unverified result must be in the review queue"
    assert_equal "unverified", item.reason
    assert_nil @participation.reload.current_decision, "an unverified result never becomes a decision by itself"
  end

  test "control: every genuine quote stays verified, so the unverified count is zero and the queue holds no unverified item" do
    result = screen!(criteria_for(@job))
    assert_equal 0, result.unverified_count
    assert result.criteria.all? { |c| c["verified"] == true }, result.criteria.map { |c| [c["key"], c["verified"]] }.inspect
    refute Screening::ReviewQueue.new(@job).items.any? { |i| i.participation.id == @participation.id && i.reason == "unverified" }
  end

  test "a quote is matched on words, not bytes: different whitespace still verifies, a changed word does not" do
    key = should_have_key
    genuine = criteria_for(@job).find { |c| c[:id] == key }[:quote]
    respaced = genuine.split.join("  \n")
    result = screen!(criteria_for(@job, quotes: { key => respaced }))
    assert_equal true, result.criteria.find { |c| c["key"] == key }["verified"], "whitespace-only differences are not a paraphrase"

    @job = screening_job # a second vacancy: one application per candidate and vacancy
    key = should_have_key
    altered = genuine.sub("Gudang", "Kantor")
    result = screen!(criteria_for(@job, quotes: { key => altered }))
    assert_equal false, result.criteria.find { |c| c["key"] == key }["verified"], "one changed word is a paraphrase, not a quote"
  end

  test "the redaction marker the demo shows is [REDACTED]" do
    assert_equal "[REDACTED]", Screening::Redactor::MARK
  end
end
