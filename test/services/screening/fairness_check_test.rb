require "test_helper"

# Build item C2 (plan A8): the fairness check. Risk hunted: a check that cannot fail. Three ways it
# could be decoration, each refuted below: the swap applied after redaction (nothing to swap, always
# "fair"); a comparison that cannot tell "the model got different bytes" from "the model answered
# differently"; and a pipeline that ignores the CV (then identical scores prove nothing, so the
# merit control must move the score). Since the end-to-end test of 16 Oct 2026 also: a rate limit
# (HTTP 429) shown as a difference between answers instead of a missing answer, and five calls where
# two distinct texts need two. Gemini is stubbed at the HTTP boundary (FakeGemini), so the request
# bodies compared here are the ones the real client built.
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

  test "through the real client: one request per distinct text, the swaps share the base's answer, the merit control moves the score" do
    result = run_check([gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    assert_equal 2, @fake.requests.size, "base, name, gender and religion are the same bytes, so one request; the control is the other"
    bodies = @fake.parsed_bodies.map { |b| request_user_text(b) }
    %i[base name gender religion].each { |key| assert_includes bodies.first, result.variants.fetch(key).redacted_text, "#{key}: its bytes are the first request" }
    refute_equal bodies.first, bodies.last, "the merit control must reach the model as different bytes"
    refute_match(/Maya|Female|Male|Islam|Christian|Daniel/, bodies.first, "a protected value or name reached the model")

    assert result.identical_to_base?
    assert result.scores_identical?
    assert result.merit_control_moved?
    assert result.complete?
    assert result.passed?
    assert_equal 2, result.calls
    assert_equal({ base: nil, name: :base, gender: :base, religion: :base, merit_control: nil }, result.variants.transform_values(&:answer_from))
    assert_equal [1], result.variants.values.map(&:attempts).uniq
    assert_equal "HIGH", result.tier
    assert_equal FAKE_MODEL, result.model_id
    assert_equal Screening::PROMPT_VERSION, result.prompt_version
    assert_equal result.base.score, result.variants.fetch(:gender).score
    assert_operator result.control.score, :<, result.base.score
    assert result.base.judgements.values.all? { |j| j["verified"] }, "every scripted quote is a verbatim line, so all verified"
  end

  test "different bytes get their own request; a different answer there is a redaction gap, never shared" do
    # Red control: a CV whose gender word sits INSIDE an evidence section. The evidence-section pass
    # does not redact such words (F-27), so the swapped bytes reach the model: a redaction gap, red.
    leaky = Screening::FairnessCheck::BASE_CV.sub("Manages 1,200 SKUs", "Female team leader who manages 1,200 SKUs")
    variants = Screening::FairnessCheck.prepare(job: @job, cv: leaky)
    refute variants.fetch(:gender).identical_to_base, "a gender word left in the evidence text must be reported as a difference"
    result = run_check([gemini_message(answer), gemini_message(answer(sebaiknya: "2")), gemini_message(answer(sebaiknya: "1"))], cv: leaky)
    assert_equal 3, @fake.requests.size, "the base's text (name and religion share it), the gender text, the control"
    gender = result.variants.fetch(:gender)
    assert_nil gender.answer_from, "different bytes are asked on their own"
    assert_equal :redaction_gap, gender.difference_kind(result.base)
    refute_equal result.base.judgements, gender.judgements
    refute result.identical_to_base?
    refute result.scores_identical?
    refute result.passed?
    assert_equal :base, result.variants.fetch(:religion).answer_from
    assert_nil result.variants.fetch(:name).difference_kind(result.base)
  end

  test "a rate limit is retried after growing pauses, then answered" do
    pauses = []
    result = run_check([gemini_error(429, "RESOURCE_EXHAUSTED"), gemini_error(503, "UNAVAILABLE"), gemini_message(answer),
                        gemini_message(answer(sebaiknya: "1"))], pause: ->(seconds) { pauses << seconds })
    assert_equal 4, @fake.requests.size, "two refused tries, the answer, then the control"
    assert_equal [2, 5], pauses.map(&:floor), "the first two waits of RETRY_WAITS, each plus under a second"
    assert_equal 3, result.base.attempts
    assert_equal 1, result.control.attempts
    assert result.passed?
  end

  test "no answer after every retry is a missing answer on each variant sharing the text: never a difference, the run incomplete" do
    pauses = []
    result = run_check([*Array.new(4) { gemini_error(429, "RESOURCE_EXHAUSTED") }, gemini_message(answer(sebaiknya: "1"))],
                       pause: ->(seconds) { pauses << seconds })
    assert_equal 5, @fake.requests.size, "four tries for the base's text (1 + 3 retries), one for the control"
    assert_equal [2, 5, 10], pauses.map(&:floor)
    %i[base name gender religion].each do |key|
      variant = result.variants.fetch(key)
      assert_match(/429/, variant.error.to_s, key)
      assert_nil variant.score
      assert_equal 4, variant.attempts
    end
    %i[name gender religion].each { |key| assert_equal :no_answer, result.variants.fetch(key).difference_kind(result.base) }
    assert_equal %i[base name gender religion], result.unanswered.map(&:key)
    refute result.complete?
    refute result.passed?
    assert result.identical_to_base?, "the bytes are a fact without any answer"
    assert_nil result.control.error
    refute result.merit_control_moved?, "nothing to compare the control with"
  end

  test "a timeout and a rejected request are not retried; the other text is still answered" do
    pauses = []
    result = run_check([Net::ReadTimeout.new, gemini_message(answer(sebaiknya: "1"))], pause: ->(seconds) { pauses << seconds })
    assert_equal 2, @fake.requests.size
    assert_empty pauses, "a timeout has used the request's time already"
    assert_match(/timeout/, result.base.error)
    assert_equal 1, result.base.attempts
    refute_nil result.control.score, "control: the control text was still answered"

    @fake = FakeGemini.new
    result = run_check([gemini_message(answer), gemini_error(403, "PERMISSION_DENIED")], pause: ->(seconds) { pauses << seconds })
    assert_empty pauses
    assert_match(/403/, result.control.error)
    assert result.scores_identical?, "the swaps still carry the base's answer"
    refute result.merit_control_moved?
    refute result.complete?
  end

  test "parallel: the distinct requests are in flight together, each answer lands on its variants, a retry stays in its thread" do
    replies = { base: answer, control: answer(sebaiknya: "1") }.transform_values do |criteria|
      JSON.generate({ criteria:, protected_attribute_seen: false, protected_attribute_categories: [] })
    end
    lock = Mutex.new
    in_flight = peak = 0
    refused = false
    judge = lambda do |content|
      control = content.include?("Basic computer use")
      lock.synchronize { peak = [peak, in_flight += 1].max }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until lock.synchronize { peak == 2 } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      lock.synchronize { in_flight -= 1 }
      # The base's text is refused once with a rate limit, as on the 16 Oct 2026 run.
      first_base_call = !control && lock.synchronize { !refused && (refused = true) }
      raise Screening::Errors::Transient.new("api_error", "HTTP 429") if first_base_call

      Screening::AiClient::Reply.new(model: FAKE_MODEL, text: replies[control ? :control : :base], input_tokens: 1, output_tokens: 1)
    end
    pauses = Queue.new
    result = Screening::FairnessCheck.call(job: @job, judge:, parallel: true, pause: ->(seconds) { pauses << seconds })
    assert_equal 2, peak, "both distinct requests must be in flight at the same time"
    assert_equal 1, pauses.size, "one retry, for the refused base text"
    assert result.passed?, "the swaps share the base's answer and the merit control moved, whatever order the replies came back in"
    assert_equal 2, result.base.attempts
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
      run_check([gemini_message(answer), gemini_message(answer(sebaiknya: "1"))])
    end
  end
end
