require "test_helper"

# Prompt s1-2026-10-16.4 through the real pipeline, the Gemini API stubbed at the HTTP boundary
# (FakeGemini), the answers in the shape the schema asks for:
#   - a rating may rest on up to three passages from different lines of the CV ("journals AND
#     bank reconciliations"); all are stored, and the criterion is verified only when every one is
#     found (an invented second passage must not ride on a real first one);
#   - the model's instruction_seen flag sends the result to the reviewer the way a protected
#     attribute does, and a flag in the wrong shape fails safe.
class Screening::PassagesAndInstructionFlagTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  TWO_LINES = ["Admin Gudang di PT Logistik Makmur", "Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan."].freeze

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @sebaiknya = rubric_keys(@job).find { |k| Requirement.find(k.delete("R")).tier == "sebaiknya" }
  end

  # criteria_for in the schema's shape (quotes lists), with per-key overrides.
  def criteria(overrides = {})
    criteria_for(@job).map do |c|
      { id: c[:id], quotes: [c[:quote]].reject(&:empty?), judgement: c[:judgement] }.merge(overrides.fetch(c[:id], {}))
    end
  end

  def answer(criteria = self.criteria, **flags)
    JSON.generate({ criteria:, protected_attribute_seen: false, protected_attribute_categories: [], instruction_seen: false }.merge(flags))
  end

  def screen(text, log: StringIO.new)
    logger = ActiveSupport::Logger.new(log)
    Rails.logger.broadcast_to(logger)
    with_ai(@fake) do
      @fake.push(gemini_message(nil, text:))
      @participation = apply_with_cv!(@job)
      screen_and_release!
    end
    @participation.screening_results.sole
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  def review_reason = Screening::ReviewQueue.new(@job).items.find { |i| i.participation.id == @participation.id }&.reason

  test "two passages from two lines back one rating: both stored in order, verified" do
    result = screen(answer(criteria(@sebaiknya => { quotes: TWO_LINES, judgement: "3" })))
    row = result.criteria.find { |c| c["key"] == @sebaiknya }
    assert_equal TWO_LINES.join(Screening::QuoteCheck::SEPARATOR), row["quote"]
    assert_equal TWO_LINES, Screening::QuoteCheck.passages(row["quote"])
    assert row["verified"]
    assert_equal 0, result.unverified_count
  end

  test "an invented second passage makes the criterion unverified although the first is real" do
    result = screen(answer(criteria(@sebaiknya => { quotes: [TWO_LINES.first, "Mengelola stok 5.000 SKU di tiga gudang"], judgement: "3" })))
    row = result.criteria.find { |c| c["key"] == @sebaiknya }
    refute row["verified"]
    assert_equal 1, result.unverified_count
    assert_equal "unverified", review_reason
  end

  test "instruction_seen true: stored as the instruction flag, held for the reviewer, only the flag logged" do
    log = StringIO.new
    result = screen(answer(instruction_seen: true), log:)
    assert_equal [Screening::AiClient::INSTRUCTION_FLAG], result.protected_attribute_categories
    assert_equal "protected_attribute", review_reason, "the same route as a protected attribute"
    assert_includes log.string, "instruction_seen"
    refute_includes log.string, "protected_attribute_seen categories=", "no protected attribute was reported"
  end

  test "instruction_seen beside a protected attribute: both kept" do
    result = screen(answer(protected_attribute_seen: true, protected_attribute_categories: %w[religion], instruction_seen: true))
    assert_equal ["religion", Screening::AiClient::INSTRUCTION_FLAG], result.protected_attribute_categories
  end

  test "a flag in the wrong shape is read as seen; false and the old shape without the flag are clean" do
    assert_equal [Screening::AiClient::INSTRUCTION_FLAG], screen(answer(instruction_seen: "yes")).protected_attribute_categories
    @job = screening_job
    assert_empty screen(answer).protected_attribute_categories
    refute_equal "protected_attribute", review_reason
    @job = screening_job
    assert_empty screen(JSON.generate({ criteria: criteria_for(@job), protected_attribute_seen: false, protected_attribute_categories: [] })).protected_attribute_categories
  end
end
