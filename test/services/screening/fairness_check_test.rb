require "test_helper"

# Build item C2 (plan A8): the fairness check. Risk hunted: a check that cannot fail. Three ways it
# could be decoration, each refuted below: the swap applied after redaction (nothing to swap, always
# "fair"); a comparison that cannot tell "the model got different bytes" from "the model answered
# differently"; and a pipeline that ignores the CV (then identical scores prove nothing, so the
# merit control must move the score). Gemini is stubbed at the HTTP boundary (FakeGemini), so the
# request bodies compared here are the ones the real client built.
class Screening::FairnessCheckTest < ActiveSupport::TestCase
  include ScreeningFactory

  setup do
    @job = screening_job
    @fake = FakeGemini.new
    @keys = rubric_keys(@job)
  end

  # Criteria whose quotes are verbatim lines of the fairness CV's evidence sections.
  def answer(sebaiknya: "3")
    quotes = { "wajib" => "D3 Logistics Management", "sebaiknya" => "Warehouse Admin at PT Logistik Makmur",
               "nilai_tambah" => "Holds a SIM C driving licence" }
    Screening::Rubric.for(@job).criteria.map do |c|
      judgement = { "wajib" => "met", "sebaiknya" => sebaiknya, "nilai_tambah" => "2" }.fetch(c.tier)
      { id: c.key, judgement:, quote: quotes.fetch(c.tier) }
    end
  end

  def run_check(replies, **)
    with_ai(@fake) do
      replies.each { |r| @fake.push(r) }
      Screening::FairnessCheck.call(job: @job, **)
    end
  end

  test "prepare: every swap changes the ORIGINAL text and leaves the redacted text byte-identical to the base" do
    variants = Screening::FairnessCheck.prepare(job: @job)
    base = variants.fetch(:base)
    refute_includes base.redacted_text, "Maya", "the name must be redacted from the evidence sections too (certificate line)"
    %i[name gender religion].each do |key|
      v = variants.fetch(key)
      assert_operator v.substitutions, :>, 0, "#{key}: the swap found nothing to change in the original text"
      assert v.original_differs, "#{key}: the swapped original equals the base original"
      assert_equal base.redacted_sha256, v.redacted_sha256, "#{key}: the model would receive different bytes"
      assert v.identical_to_base
    end
    control = variants.fetch(:merit_control)
    assert_operator control.substitutions, :>, 0
    refute control.identical_to_base, "the merit control must change what the model sees"
  end

  test "control: the same swaps applied AFTER redaction find nothing to swap, so that ordering could never fail" do
    base = Screening::FairnessCheck.prepare(job: @job).fetch(:base)
    Screening::FairnessCheck::VARIANTS.each do |key, (_label, substitutions, kind)|
      next unless kind == :swap

      _text, count = Screening::FairnessCheck.apply_swaps(base.redacted_text, substitutions)
      assert_equal 0, count, "#{key}: a swap after redaction still changed the text, so the before/after distinction is not what this test assumes"
    end
  end

  test "through the real client: the four swap-family requests are byte-identical, scores identical, the merit control moves the score" do
    result = run_check([gemini_message(answer), gemini_message(answer), gemini_message(answer), gemini_message(answer),
                        gemini_message(answer(sebaiknya: "1"))])
    assert_equal 5, @fake.requests.size
    bodies = @fake.parsed_bodies.map { |b| request_user_text(b) }
    assert_equal 1, bodies.first(4).uniq.size, "base, name, gender and religion must reach the model as the same bytes"
    refute_equal bodies.first, bodies.last, "the merit control must reach the model as different bytes"
    refute_match(/Maya|Female|Male|Islam|Christian|Daniel/, bodies.first(4).join, "a protected value or name reached the model")

    assert result.identical_to_base?
    assert result.scores_identical?
    assert result.merit_control_moved?
    assert result.passed?
    assert_equal "HIGH", result.tier
    assert_equal FAKE_MODEL, result.model_id
    assert_equal Screening::PROMPT_VERSION, result.prompt_version
    assert_equal result.base.score, result.variants.fetch(:gender).score
    assert_operator result.control.score, :<, result.base.score
    assert result.base.judgements.values.all? { |j| j["verified"] }, "every scripted quote is a verbatim line, so all verified"
  end

  test "same bytes, different answer is labelled model variance, never bias; different bytes is a redaction gap" do
    # The fake answers the gender variant with a lower rating although its input is identical.
    result = run_check([gemini_message(answer), gemini_message(answer), gemini_message(answer(sebaiknya: "2")),
                        gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    assert result.identical_to_base?, "digests are a separate fact from scores"
    refute result.scores_identical?
    refute result.passed?
    assert_equal :same_input_different_answer, result.variants.fetch(:gender).difference_kind(result.base)
    assert_nil result.variants.fetch(:name).difference_kind(result.base)

    # Red control: a CV whose gender word sits INSIDE an evidence section. The evidence-section pass
    # does not redact such words (F-27), so the swapped bytes reach the model: a redaction gap, red.
    leaky = Screening::FairnessCheck::BASE_CV.sub("Manages 1,200 SKUs", "Female team leader who manages 1,200 SKUs")
    variants = Screening::FairnessCheck.prepare(job: @job, cv: leaky)
    refute variants.fetch(:gender).identical_to_base, "a gender word left in the evidence text must be reported as a difference"
    @fake = FakeGemini.new
    result = run_check(Array.new(5) { gemini_message(answer) }, cv: leaky)
    refute result.identical_to_base?
    assert_equal :redaction_gap, result.variants.fetch(:gender).difference_kind(result.base)
  end

  test "a provider error on one variant is recorded on that variant; the others still carry evidence" do
    result = run_check([gemini_message(answer), gemini_error(503, "UNAVAILABLE"), gemini_message(answer), gemini_message(answer),
                        gemini_message(answer(sebaiknya: "1"))])
    assert_match(/Unavailable|503|UNAVAILABLE|Transient/i, result.variants.fetch(:name).error.to_s)
    assert_nil result.variants.fetch(:name).score
    refute result.scores_identical?
    assert result.merit_control_moved?
    assert_equal result.base.judgements, result.variants.fetch(:religion).judgements
  end

  test "parallel: the five requests are in flight together and each reply lands on its own variant" do
    replies = { base: answer, control: answer(sebaiknya: "1") }.transform_values do |criteria|
      JSON.generate({ criteria:, protected_attribute_seen: false, protected_attribute_categories: [] })
    end
    lock = Mutex.new
    in_flight = peak = 0
    judge = lambda do |content|
      lock.synchronize { peak = [peak, in_flight += 1].max }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until lock.synchronize { peak == 5 } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      lock.synchronize { in_flight -= 1 }
      text = content.include?("Basic computer use") ? replies[:control] : replies[:base]
      Screening::AiClient::Reply.new(model: FAKE_MODEL, text:, input_tokens: 1, output_tokens: 1)
    end
    result = Screening::FairnessCheck.call(job: @job, judge:, parallel: true)
    assert_equal 5, peak, "all five requests must be in flight at the same time"
    assert result.passed?, "the swaps match the base and the merit control moved, whatever order the replies came back in"
    assert_operator result.control.score, :<, result.base.score

    # Control: with a judge seam the default stays sequential, so scripted replies keep their order.
    in_flight = peak = 0
    counting = lambda do |content|
      lock.synchronize { peak = [peak, in_flight += 1].max }
      sleep 0.01
      lock.synchronize { in_flight -= 1 }
      Screening::AiClient::Reply.new(model: FAKE_MODEL, text: replies[content.include?("Basic computer use") ? :control : :base],
                                     input_tokens: 1, output_tokens: 1)
    end
    Screening::FairnessCheck.call(job: @job, judge: counting)
    assert_equal 1, peak
  end

  test "the fairness CV never goes through a release: no AiRelease row and no applicant is written" do
    assert_no_difference(["AiRelease.count", "Candidate.count", "JobApplication.count", "ScreeningResult.count"]) do
      run_check(Array.new(5) { gemini_message(answer) })
    end
  end
end
