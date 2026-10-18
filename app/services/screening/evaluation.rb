module Screening
  # The agreement and cost check (FLOW v2.1 §1 "Checks on top of the flow"; plan task A9): the
  # invented CVs of the demo seed are screened with the real prompt, schema, evidence-section filter,
  # redactor and evidence check, and every AI judgement is set beside the judgement a person gave the
  # same requirement (the hand scores, generated from the same seed). It measures what the deck and the README may claim, from one run, never an estimate:
  #   - agreement per requirement, per tier and overall, with n; for 0-3 ratings also within one point;
  #   - the S1 outcome (pass / eliminate at the vacancy's pass score) the AI judgements lead to,
  #     against the outcome of the hand judgements, and the score difference;
  #   - the share of the AI's positive judgements whose quote the evidence check finds;
  #   - tokens per CV (input, output, thinking) and seconds per call; cost per 100 CVs only when the
  #     prices are given (a guessed price is not a measurement).
  #
  # Invented data only: the cases are built from the seed's constants, never from the database, so
  # no applicant record and no release is involved. Like FairnessCheck it sends through
  # AiClient#generate, the documented path for text without candidate data. Nothing is stored.
  class Evaluation
    Requirement = Struct.new(:id, :tier, :text, :cv_evidence, :weight, :position)
    Case = Data.define(:key, :vacancy, :threshold, :rubric, :codes, :cv, :name, :hand)
    Row = Data.define(:cv_id, :vacancy, :code, :tier, :requirement, :hand, :ai, :hand_quote, :ai_quote, :verified) do
      def rating? = tier != "wajib"
      def agree? = hand == ai
      def within_one? = rating? ? (hand.to_i - ai.to_i).abs <= 1 : agree?
      # How far apart: points on the 0-3 scale; a must-have mismatch counts as the full scale.
      def distance = rating? ? (hand.to_i - ai.to_i).abs : (agree? ? 0 : Score::TOP)
    end
    # flags: what the model reported beside the judgements (protected categories, and
    # AiClient::INSTRUCTION_FLAG). The invented CVs hold no instruction and, after redaction, no
    # protected attribute, so every flag here is a false alarm a reviewer would have to clear.
    # rate_limited: HTTP 429 answers waited out before this call's answer (not billed).
    Call = Data.define(:cv_id, :model, :input_tokens, :output_tokens, :thinking_tokens, :seconds, :error, :flags, :rate_limited) do
      def initialize(cv_id:, model:, input_tokens:, output_tokens:, thinking_tokens:, seconds:, error:, flags: [], rate_limited: 0) = super
    end
    Outcome = Data.define(:cv_id, :vacancy, :hand_score, :ai_score, :hand_outcome, :ai_outcome) do
      def agree? = hand_outcome == ai_outcome
    end

    class Malformed < StandardError; end

    # The brief's English tier words; the stored values stay in the database.
    TIER_WORDS = { "wajib" => "must-have", "sebaiknya" => "should-have", "nilai_tambah" => "nice-to-have" }.freeze

    # The 25 invented applicants of db/seeds/demo_glassbox.rb, each with its vacancy's rubric and the
    # hand judgement per requirement code. Requirement ids are local (R1..R4 per vacancy).
    def self.demo_cases
      require Rails.root.join("db/seeds/demo_glassbox").to_s
      DemoGlassbox::PEOPLE.map do |person|
        spec = DemoGlassbox::JOBS.fetch(person[:job])
        requirements = spec[:requirements].each_with_index.map do |(_code, tier, text, evidence, weight), i|
          Requirement.new(i + 1, tier, text, evidence, weight, i + 1)
        end
        Case.new(key: person[:key], vacancy: spec[:title], threshold: spec[:threshold], rubric: Rubric.new(requirements),
                 codes: spec[:requirements].each_with_index.to_h { |(code, *), i| ["R#{i + 1}", code] },
                 cv: DemoGlassbox.cv_text(person), name: person[:name], hand: person[:hand])
      end
    end

    # A judge that answers with the hand judgements themselves: a dry run of the whole harness
    # without a model call (agreement must come out at 100%).
    def self.hand_judge
      lambda do |_content, kase|
        criteria = kase.rubric.criteria.map do |c|
          judgement, quote = kase.hand.fetch(kase.codes.fetch(c.key))
          { id: c.key, quotes: [quote].reject(&:empty?), judgement: }
        end
        text = JSON.generate({ criteria:, protected_attribute_seen: false, protected_attribute_categories: [], instruction_seen: false })
        AiClient::Reply.new(model: "hand-scores (dry run)", text:, input_tokens: 0, output_tokens: 0, thinking_tokens: 0)
      end
    end

    # A rate-limited call (HTTP 429: refused before the model ran, so not billed) is sent again
    # after each of these waits, in seconds; then it counts as a CV without an answer. The run of
    # 16 Oct lost 2 of 25 CVs to 429. Other failures, a timeout included (it may be billed), are
    # never repeated.
    RATE_LIMIT_WAITS = [15, 45].freeze

    # judge: (content, case) -> AiClient::Reply; default: the screening task's client (tier HIGH),
    # one client per worker thread. threads: calls in flight at once.
    def self.call(cases: demo_cases, judge: nil, threads: 4, waits: RATE_LIMIT_WAITS) = new(cases:, judge:, threads:, waits:).call

    def initialize(cases:, judge: nil, threads: 4, waits: RATE_LIMIT_WAITS)
      @cases = cases
      @judge = judge
      @threads = threads.to_i.clamp(1, 16)
      @waits = waits
    end

    def call
      screened = run_all
      rows = []
      calls = []
      outcomes = []
      @cases.zip(screened).each do |kase, (reply, seconds, judgements, error, flags, rate_limited)|
        calls << Call.new(cv_id: kase.key, model: reply&.model, input_tokens: reply&.input_tokens.to_i,
                          output_tokens: reply&.output_tokens.to_i, thinking_tokens: reply&.thinking_tokens.to_i,
                          seconds:, error:, flags: flags.to_a, rate_limited: rate_limited.to_i)
        next if judgements.nil?

        kase.rubric.criteria.each do |c|
          hand, hand_quote = kase.hand.fetch(kase.codes.fetch(c.key))
          ai = judgements.fetch(c.key)
          rows << Row.new(cv_id: kase.key, vacancy: kase.vacancy, code: kase.codes.fetch(c.key), tier: c.tier,
                          requirement: c.text, hand:, ai: ai["judgement"], hand_quote:, ai_quote: ai["quote"], verified: ai["verified"])
        end
        outcomes << outcome(kase, judgements)
      end
      Report.new(rows:, calls:, outcomes:, prompt_version: PROMPT_VERSION, tier: Config.tier(:screening).to_s.upcase)
    end

    private

    def run_all
      queue = Queue.new
      @cases.each_with_index { |kase, i| queue << [kase, i] }
      results = Array.new(@cases.size)
      workers = Array.new([@threads, @cases.size].min) do
        judge = @judge || client_judge
        Thread.new do
          Rails.application.executor.wrap do
            while (item = next_item(queue))
              kase, i = item
              results[i] = screen(kase, judge)
            end
          end
        end
      end
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { workers.each(&:join) }
      results
    end

    def next_item(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    def client_judge
      client = Config.client(:screening)
      ->(content, _kase) { client.generate(system: AiClient::SYSTEM_PROMPT, schema: AiClient::SCHEMA, content:) }
    end

    # The same text Screening::ReleaseGate prepares: evidence sections, then the redactor with the
    # applicant's own name. Returns [reply, seconds, judgements or nil, error or nil, flags, rate-limited answers].
    def screen(kase, judge)
      redacted = Redactor.call(EvidenceSections.keep(kase.cv, groups: CvSections::DEFAULT).to_s, names: [kase.name]).text
      rate_limited = 0
      begin
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reply = judge.call(AiClient.user_content(redacted, kase.rubric.payload), kase)
      rescue Errors::Transient => e
        raise unless e.detail == "HTTP 429" && (wait = @waits[rate_limited])

        rate_limited += 1
        sleep(wait)
        retry
      end
      seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
      judgements, flags = parse(reply.text, kase.rubric, extracted: kase.cv, redacted:)
      [reply, seconds, judgements, nil, flags, rate_limited]
    rescue Errors::Base, Errors::NotConfigured, Errors::Unreleased, Malformed => e
      [reply, seconds, nil, "#{e.class.name.demodulize}: #{e.message}"[0, 200], [], rate_limited]
    end

    # The per-criterion rules of Screening::Run#parse: every requirement exactly once, a judgement
    # allowed for its tier, each quote through the evidence check exactly as a real run checks it
    # (every passage of a criterion, QuoteCheck.check). Returns [judgements, flags]; flags as
    # Call#flags, read as plainly as the answer gives them (the run's fail-safe reading of a
    # malformed flag is not measured here).
    def parse(text, rubric, extracted:, redacted:)
      data = JSON.parse(text)
      entries = data.is_a?(Hash) ? data["criteria"] : nil
      raise Malformed, "the answer is not in the expected shape" unless entries.is_a?(Array)

      judgements = {}
      entries.each do |entry|
        criterion = entry.is_a?(Hash) ? rubric.by_key[entry["id"].to_s] : nil
        raise Malformed, "unknown requirement id" if criterion.nil?
        raise Malformed, "requirement judged twice" if judgements.key?(criterion.key)

        judgement = entry["judgement"].to_s
        raise Malformed, "judgement not allowed for the tier" unless Rubric::JUDGEMENTS.fetch(criterion.tier).include?(judgement)

        judgements[criterion.key] = { "judgement" => judgement, **QuoteCheck.check(entry, judgement:, extracted:, redacted:) }
      end
      missing = rubric.criteria.map(&:key) - judgements.keys
      raise Malformed, "#{missing.size} requirement(s) not judged" if missing.any?

      flags = []
      flags += Array(data["protected_attribute_categories"]).map(&:to_s).presence || ["other"] if data["protected_attribute_seen"] == true
      flags << AiClient::INSTRUCTION_FLAG if data["instruction_seen"] == true
      [judgements, flags]
    rescue JSON::ParserError
      raise Malformed, "the answer is not JSON"
    end

    def outcome(kase, judgements)
      hand = kase.rubric.criteria.to_h do |c|
        judgement, quote = kase.hand.fetch(kase.codes.fetch(c.key))
        [c.key, { "judgement" => judgement, "quote" => quote, "verified" => true }]
      end
      hand_score = Score.compute(kase.rubric, hand)
      ai_score = Score.compute(kase.rubric, judgements)
      decide = ->(s) { Score.outcome(wajib_met: s.wajib_met, score: s.score, threshold: kase.threshold).outcome }
      Outcome.new(cv_id: kase.key, vacancy: kase.vacancy, hand_score: hand_score.score.to_f, ai_score: ai_score.score.to_f,
                  hand_outcome: decide.call(hand_score), ai_outcome: decide.call(ai_score))
    end

    # The measures and their printouts. prices: { input:, output: } in USD per one million tokens
    # (thinking is billed as output); nil = no cost line.
    Report = Data.define(:rows, :calls, :outcomes, :prompt_version, :tier) do
      def answered = calls.count { |c| c.error.nil? }
      def models = calls.filter_map(&:model).uniq
      def must = rows.reject(&:rating?)
      def ratings = rows.select(&:rating?)
      def share(list, &) = list.empty? ? nil : list.count(&).fdiv(list.size)
      def positives = rows.select { |r| QuoteCheck.positive?(r.ai) }
      def mean(values) = values.empty? ? nil : values.sum.fdiv(values.size)

      def p95(values)
        return nil if values.empty?

        values.sort[((values.size - 1) * 0.95).round]
      end

      def per_call(field) = mean(calls.select { |c| c.error.nil? }.map { |c| c.public_send(field).to_i })
      # Answered CVs the model flagged: a protected attribute, or instruction-like text.
      def protected_flagged = calls.count { |c| c.error.nil? && (c.flags - [AiClient::INSTRUCTION_FLAG]).any? }
      def instruction_flagged = calls.count { |c| c.error.nil? && c.flags.include?(AiClient::INSTRUCTION_FLAG) }
      def seconds = calls.select { |c| c.error.nil? && c.seconds }.map(&:seconds)

      def cost_per_100(prices)
        return nil unless prices && answered.positive?

        input = per_call(:input_tokens) * prices.fetch(:input)
        output = (per_call(:output_tokens) + per_call(:thinking_tokens)) * prices.fetch(:output)
        (input + output) / 1_000_000 * 100
      end

      # [vacancy, code, requirement, tier, exact, within one, n] per requirement, in seed order.
      def per_requirement
        rows.group_by { |r| [r.vacancy, r.code] }.map do |(vacancy, code), list|
          [vacancy, code, list.first.requirement, list.first.tier, share(list, &:agree?), share(list, &:within_one?), list.size]
        end
      end

      def largest_disagreements(count = 3) = rows.reject(&:agree?).sort_by { |r| [-r.distance, r.cv_id, r.code] }.first(count)

      def to_markdown(prices: nil, at: Time.current)
        pct = ->(v) { v.nil? ? "n/a" : format("%.1f%%", v * 100) }
        num = ->(v, d = 0) { v.nil? ? "n/a" : ActiveSupport::NumberHelper.number_to_delimited(v.round(d), delimiter: ",", separator: ".") }
        cost = cost_per_100(prices)
        lines = []
        lines << "# Agreement check: Gemini AI advice vs hand scores"
        lines << ""
        lines << "Prompt #{prompt_version} · Tier #{tier} · model #{models.join(', ').presence || 'none'} · run #{at.utc.iso8601} · " \
                 "invented data only (#{calls.size} CVs, #{rows.map(&:vacancy).uniq.size} vacancies) · #{answered} of #{calls.size} CVs answered"
        lines << ""
        lines << "| Measure | Result | n |"
        lines << "|---|---|---|"
        lines << "| Must-have judgements (met / not met), agreement | #{pct.(share(must, &:agree?))} | #{must.size} |"
        lines << "| Should-have and nice-to-have ratings (0-3), exact | #{pct.(share(ratings, &:agree?))} | #{ratings.size} |"
        lines << "| Should-have and nice-to-have ratings, within one point | #{pct.(share(ratings, &:within_one?))} | #{ratings.size} |"
        lines << "| All judgements, exact | #{pct.(share(rows, &:agree?))} | #{rows.size} |"
        lines << "| S1 outcome (pass / eliminate at the pass score), agreement | #{pct.(share(outcomes, &:agree?))} | #{outcomes.size} |"
        lines << "| Mean absolute S1 score difference (0-100) | #{num.(mean(outcomes.map { |o| (o.hand_score - o.ai_score).abs }), 1)} | #{outcomes.size} |"
        lines << "| AI positive judgements whose quote the evidence check finds | #{pct.(share(positives, &:verified))} | #{positives.size} |"
        lines << "| Tokens per CV: input / output / thinking | #{num.(per_call(:input_tokens))} / #{num.(per_call(:output_tokens))} / #{num.(per_call(:thinking_tokens))} | #{answered} |"
        lines << "| Seconds per CV: mean / p95 | #{num.(mean(seconds), 1)} / #{num.(p95(seconds), 1)} | #{seconds.size} |"
        if cost
          lines << "| Cost per 100 CVs (USD; input #{prices[:input]}, output and thinking #{prices[:output]} per 1M tokens) | #{format('%.2f', cost)} | #{answered} |"
        end
        lines << "| CVs the model flagged: protected attribute / instruction-like text (the set holds neither, so each is a false alarm) | " \
                 "#{protected_flagged} / #{instruction_flagged} | #{answered} |"
        retried = calls.sum(&:rate_limited)
        lines << "| Rate-limited answers (HTTP 429, not billed) waited out and sent again | #{retried} | #{calls.size} |" if retried.positive?
        lines << ""
        lines << "## Agreement per requirement"
        lines << ""
        lines << "| Vacancy | Code | Requirement | Tier | Exact | Within one | n |"
        lines << "|---|---|---|---|---|---|---|"
        per_requirement.each do |v, code, text, t, exact, one, n|
          lines << "| #{v} | #{code} | #{text} | #{TIER_WORDS.fetch(t, t)} | #{pct.(exact)} | #{pct.(one)} | #{n} |"
        end
        lines << ""
        lines << "## The largest disagreements"
        lines << ""
        if largest_disagreements.empty?
          lines << "None: every AI judgement equals the hand judgement."
        else
          lines << "| CV | Requirement | Hand | AI | Hand quote | AI quote (verified?) |"
          lines << "|---|---|---|---|---|---|"
          largest_disagreements.each do |r|
            lines << "| #{r.cv_id} | #{r.code} #{r.requirement} | #{r.hand} | #{r.ai} | #{r.hand_quote.presence || '(none)'} | #{r.ai_quote.presence || '(none)'} (#{r.verified ? 'yes' : 'no'}) |"
          end
        end
        flagged = calls.select { |c| c.error.nil? && c.flags.any? }
        if flagged.any?
          lines << ""
          lines << "## CVs the model flagged"
          lines << ""
          flagged.each { |c| lines << "- #{c.cv_id}: #{c.flags.join(', ')}" }
        end
        errors = calls.select(&:error)
        if errors.any?
          lines << ""
          lines << "## CVs without a usable answer"
          lines << ""
          errors.each { |c| lines << "- #{c.cv_id}: #{c.error}" }
        end
        lines.join("\n") + "\n"
      end

      def to_csv
        header = %w[cv_id vacancy requirement_code tier requirement hand_judgement ai_judgement agree within_one hand_quote ai_quote ai_quote_verified]
        body = rows.map do |r|
          [r.cv_id, r.vacancy, r.code, TIER_WORDS.fetch(r.tier, r.tier), r.requirement, r.hand, r.ai, r.agree?, r.within_one?, r.hand_quote, r.ai_quote, r.verified]
        end
        ([header] + body).map { |row| row.map { |f| %("#{f.to_s.gsub('"', '""')}") }.join(",") + "\n" }.join
      end
    end
  end
end
