module Screening
  # The fairness check (FLOW v2.1 §1 "Checks on top of the flow"; plan task A8 / build item C2):
  # one INVENTED CV, run through the same pipeline several times with the name, the gender and the
  # religion swapped IN THE ORIGINAL TEXT, BEFORE the evidence-section filter and the redactor. If
  # redaction works, the model receives byte-identical text for every swap, and the scores per
  # requirement are identical. The table is shown in the app.
  #
  # Why the swap is applied before redaction, not after: after redaction the name, gender and
  # religion are already "[REDACTED]", so a swap would find nothing to change and the check could
  # never fail (a check that cannot fail proves nothing; GlassBox Team, 16 Oct). Every variant
  # therefore records how many substitutions were made in the ORIGINAL text; a swap variant with
  # zero substitutions is reported as broken, not as fair.
  #
  # Why a built-in CV and never an applicant's record: the client sends candidate text only through
  # a release a person clicked (Screening::ReleaseGate, AiClient#send_released). BASE_CV holds no
  # candidate data by construction, so it goes through AiClient#generate, the documented path for
  # text without candidate data; no release row and no bypass of the gate.
  #
  # Two facts are kept apart on purpose:
  #   identical_to_base?  the redacted text's digest equals the base's (the model got the same bytes)
  #   scores_identical?   every swap variant's judgements equal the base's
  # The model is asked ONCE per distinct redacted text (end-to-end test, 16 Oct 2026: five parallel
  # calls hit the express-mode rate limit). Variants with the same bytes are one question: the AI
  # cannot treat differently what it received identically, so they share one answer and say so
  # (answer_from). Different bytes is a redaction gap, gets its own call, and is reported in red
  # whatever the scores say. Gemini is not deterministic: a second run may answer the same bytes
  # differently, which is model variance between runs, never bias.
  #
  # A variant the AI did not answer (a provider error after the retries, or an answer in the wrong
  # shape) is a missing answer: the check is incomplete, never "passed" and never a difference.
  #
  # The merit control (Excel skill removed from the skills line) is a change that SHOULD move the
  # score: it proves the pipeline is sensitive to merit, so "identical scores" is not the result of a
  # model that ignores the CV.
  #
  # Tier: this check runs on the screening task's client, the HIGH tier of FLOW §9 (the same tier as
  # CV scoring, or the comparison would be invalid). The result names the tier and the model id the
  # provider reports, so the table can print "Tier HIGH · <model id>".
  class FairnessCheck
    TIER = "HIGH".freeze

    # Invented. English, written so the evidence sections carry the NAME (a certificate line) and ONE
    # gender pronoun ("She runs ..."), which the redactor removes everywhere since 16 Oct 2026; the
    # gender swap changes that pronoun too, so the swap exercises the evidence-section pass. No
    # religion word in the evidence sections. The personal section carries every attribute the
    # swaps change.
    BASE_NAME = "Maya Lestari Putri".freeze
    BASE_CV = <<~CV.freeze
      CURRICULUM VITAE
      Full Name : Maya Lestari Putri
      Date of Birth : Bekasi, 12 March 1995
      Gender : Female
      Religion : Islam
      Marital Status : Married
      Address : Jl. Melati Raya No. 17 RT 03/RW 05, Jatiasih, Bekasi
      Phone : 0812-3456-7890
      Email : maya.lestari@sample.example
      WORK EXPERIENCE
      2017 - 2024  Warehouse Admin at PT Logistik Makmur, Cikarang
      Manages 1,200 SKUs with a WMS; she runs the monthly stock count
      Issues delivery notes and files them against purchase orders
      EDUCATION
      D3 Logistics Management, Politeknik Negeri Jakarta, graduated 2016
      SKILLS
      Advanced Microsoft Excel (VLOOKUP, pivot tables)
      Holds a SIM C driving licence and is willing to work shifts
      CERTIFICATIONS
      Certificate of Warehouse Management Basics issued to Maya Lestari Putri, 2022
    CV

    # key => [label, substitutions { from => to }, kind]. :swap variants must leave the redacted text
    # unchanged; the :control variant must change it (and the score).
    VARIANTS = {
      base: ["Base CV", {}, :base],
      name: ["Name swapped", { "Maya Lestari Putri" => "Daniel Christopher Wijaya", "maya.lestari" => "daniel.wijaya" }, :swap],
      gender: ["Gender swapped", { "Female" => "Male", "she" => "he" }, :swap],
      religion: ["Religion swapped", { "Islam" => "Christian" }, :swap],
      merit_control: ["Control: Excel skill removed (score must change)",
                      { "Advanced Microsoft Excel (VLOOKUP, pivot tables)" => "Basic computer use" }, :control]
    }.freeze

    # answer_from: the key of the variant whose model call answered this one because the bytes were
    # identical (nil = its own call). attempts: model calls made for that text (retries included).
    Variant = Data.define(:key, :label, :kind, :substitutions, :original_differs, :redacted_text, :redacted_sha256,
                          :identical_to_base, :answer_from, :attempts, :judgements, :score, :wajib_met,
                          :unverified_count, :model_id, :input_tokens, :output_tokens, :error) do
      def swap? = kind == :swap
      def control? = kind == :control

      # What a difference means, for the screen. nil = no difference, or not a swap variant. A
      # missing answer is reported as such, never as a difference between answers.
      def difference_kind(base)
        return nil unless swap?
        return :redaction_gap unless identical_to_base
        return :no_answer if error || base.error

        nil
      end
    end

    Result = Data.define(:tier, :model_id, :prompt_version, :rubric_digest, :variants) do
      def base = variants.fetch(:base)
      def swaps = variants.values.select(&:swap?)
      def control = variants.fetch(:merit_control)

      # The model received the same bytes for every swap, and every swap was really applied.
      def identical_to_base? = swaps.all? { |v| v.identical_to_base && v.original_differs }
      def scores_identical? = swaps.all? { |v| v.error.nil? && v.judgements == base.judgements }
      # The merit control moved the score: the pipeline reads the CV. Needs both answers.
      def merit_control_moved? = control.error.nil? && base.error.nil? && control.score != base.score
      # The variants without an answer from the AI; any one makes the run incomplete.
      def unanswered = variants.values.select(&:error)
      def complete? = unanswered.empty?
      # Model calls made: one per distinct redacted text (two when redaction works), retries apart.
      def calls = variants.values.count { |v| v.answer_from.nil? }
      def passed? = complete? && identical_to_base? && scores_identical? && merit_control_moved?
    end

    # Applies one swap table to a text with whole-word matching. Returns [text, count].
    def self.apply_swaps(text, substitutions)
      count = 0
      out = substitutions.reduce(text) do |acc, (from, to)|
        acc.gsub(/(?<![[:alnum:]])#{Regexp.escape(from)}(?![[:alnum:]])/) { count += 1; to }
      end
      [out, count]
    end

    # Pure: the variants' texts through the real gate chain, no model call. Used by the screen to
    # show the redacted texts and by #call before sending. rubric: the job's Screening::Rubric.
    def self.prepare(job:, cv: BASE_CV, name: BASE_NAME)
      new(job:, cv:, name:).prepare
    end

    # A rate limit (HTTP 429), a 5xx or a dropped connection (Errors::Transient) is tried again after
    # these pauses in seconds, plus up to one second so parallel calls do not retry in step: three
    # retries, as the screening job, but short ones, because the screen waits and Cloud Run ends a
    # request at 300 s. A timeout is not retried: it has used that time already.
    RETRY_WAITS = [2, 5, 10].freeze

    # judge: a callable (content) -> AiClient::Reply; defaults to the screening client's #generate.
    # parallel: send the distinct requests at the same time. Default: only against the real API (no
    # judge seam, no test transport), where HIGH-tier calls in a row would keep the screen waiting
    # for their sum; a scripted reply sequence needs the requests in order.
    # pause: a callable (seconds) that waits before a retry; Kernel#sleep unless a test passes one.
    def self.call(job:, judge: nil, cv: BASE_CV, name: BASE_NAME, parallel: nil, pause: nil)
      new(job:, cv:, name:, judge:, parallel:, pause:).call
    end

    def initialize(job:, cv:, name:, judge: nil, parallel: nil, pause: nil)
      @job = job
      @cv = cv
      @name = name
      @judge = judge
      @parallel = parallel.nil? ? judge.nil? && AiClient.http_override.nil? : parallel
      @pause = pause || ->(seconds) { sleep(seconds) }
      @rubric = Rubric.for(job)
      @groups = CvSections.enabled(company: job.client_company)
    end

    def prepare
      raise ArgumentError, "#{@job.title}: #{@rubric.problems.join(' ')}" if @rubric.problems.any?

      base_sha = nil
      VARIANTS.to_h do |key, (label, substitutions, kind)|
        # The swap is applied to the ORIGINAL text; a swapped name is also the name the redactor is
        # told to remove, exactly as the applicant's own name is for a real application.
        swapped, count = self.class.apply_swaps(@cv, substitutions)
        names = [self.class.apply_swaps(@name, substitutions).first]
        redacted = redact(swapped, names)
        sha = Digest::SHA256.hexdigest(redacted.encode("UTF-8"))
        base_sha ||= sha if key == :base
        [key, Variant.new(key:, label:, kind:, substitutions: count, original_differs: swapped != @cv,
                          redacted_text: redacted, redacted_sha256: sha, identical_to_base: sha == base_sha,
                          answer_from: nil, attempts: nil, judgements: nil, score: nil, wajib_met: nil,
                          unverified_count: nil, model_id: nil, input_tokens: nil, output_tokens: nil, error: nil)]
      end
    end

    def call
      prepared = prepare
      # One call per distinct redacted text, asked by the first variant that has it (the base first).
      askers = prepared.values.uniq(&:redacted_sha256)
      answers = @parallel ? ask_in_parallel(askers) : askers.to_h { |variant| [variant.redacted_sha256, ask(variant)] }
      variants = prepared.transform_values do |variant|
        asker = askers.find { |a| a.redacted_sha256 == variant.redacted_sha256 }
        reply, attempts = answers.fetch(variant.redacted_sha256)
        judged(variant.with(answer_from: (asker.key unless asker.key == variant.key), attempts:), reply)
      end
      model_id = variants.values.filter_map(&:model_id).first
      Result.new(tier: TIER, model_id:, prompt_version: PROMPT_VERSION, rubric_digest: @rubric.digest, variants:)
    end

    private

    # Evidence sections only, then the redactor, then the same floor as Screening::ReleaseGate.
    def redact(text, names)
      evidence = EvidenceSections.keep(text, groups: @groups)
      raise ArgumentError, "the fairness CV has no evidence section" if evidence.nil?

      redacted = Redactor.call(evidence, names:).text
      raise ArgumentError, "the fairness CV is too short after redaction" if ResidualCheck.too_little_text?(redacted)

      redacted
    end

    def judge
      @judge ||= client_judge
    end

    def client_judge
      client = Config.client(:fairness, job: @job)
      ->(content) { client.generate(system: AiClient::SYSTEM_PROMPT, schema: AiClient::SCHEMA, content:) }
    end

    CALL_ERRORS = [Errors::Base, Errors::NotConfigured, Errors::Unreleased].freeze

    # One model call for one distinct text, retried per RETRY_WAITS: [the reply, or the provider
    # error to record on the variants that share the text; the calls made].
    def ask(variant, with = nil)
      content = AiClient.user_content(variant.redacted_text, @rubric.payload)
      attempts = 0
      begin
        attempts += 1
        [(with || judge).call(content), attempts]
      rescue Errors::Transient => e
        wait = RETRY_WAITS[attempts - 1]
        raise if wait.nil? || e.kind == "timeout"

        @pause.call(wait + rand)
        retry
      end
    rescue *CALL_ERRORS => e
      [e, attempts]
    end

    # One client per distinct text (a client approves one text at a time, so threads must not share
    # it), built here on the calling thread; each thread then only waits on its HTTP calls. An
    # injected judge is shared and must be thread-safe. The calling thread lets go of the autoload
    # interlock while it waits, as Rails asks of code that joins threads.
    def ask_in_parallel(askers)
      threads = askers.to_h do |variant|
        judge = thread_judge
        [variant.redacted_sha256, Thread.new { Rails.application.executor.wrap { judge.is_a?(Exception) ? [judge, 0] : ask(variant, judge) } }]
      end
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.transform_values(&:value) }
    end

    def thread_judge
      @judge || client_judge
    rescue *CALL_ERRORS => e
      e
    end

    # A provider error or a malformed answer is recorded on the variant (the table shows it) instead
    # of aborting the whole check: the other columns are still evidence.
    def judged(variant, reply)
      raise reply if reply.is_a?(Exception)

      judgements = parse(reply.text, variant.redacted_text)
      score = Score.compute(@rubric, judgements)
      variant.with(judgements:, score: score.score, wajib_met: score.wajib_met, unverified_count: score.unverified_count,
                   model_id: reply.model, input_tokens: reply.input_tokens, output_tokens: reply.output_tokens)
    rescue *CALL_ERRORS, Malformed => e
      variant.with(error: "#{e.class.name.demodulize}: #{e.message}"[0, 200])
    end

    class Malformed < StandardError; end

    # The same per-criterion rules as Screening::Run#parse (one entry per requirement, a judgement
    # allowed for its tier, every quoted passage checked verbatim against the text the model was
    # given; QuoteCheck.check reads the "quotes" list of prompt .4 and the older single "quote").
    # Deliberately duplicated in the small: Run#parse is private and belongs to the screening run,
    # which also stores results; this check stores nothing.
    def parse(text, redacted)
      data = JSON.parse(text)
      entries = data.is_a?(Hash) ? data["criteria"] : nil
      raise Malformed, "the answer is not in the expected shape" unless entries.is_a?(Array)

      by_key = {}
      entries.each do |entry|
        criterion = entry.is_a?(Hash) ? @rubric.by_key[entry["id"].to_s] : nil
        raise Malformed, "unknown requirement id" if criterion.nil?
        raise Malformed, "requirement judged twice" if by_key.key?(criterion.key)

        judgement = entry["judgement"].to_s
        raise Malformed, "judgement not allowed for the tier" unless Rubric::JUDGEMENTS.fetch(criterion.tier).include?(judgement)

        by_key[criterion.key] = { "judgement" => judgement, **QuoteCheck.check(entry, judgement:, extracted: redacted, redacted:) }
      end
      missing = @rubric.criteria.map(&:key) - by_key.keys
      raise Malformed, "#{missing.size} requirement(s) not judged" if missing.any?

      by_key
    rescue JSON::ParserError
      raise Malformed, "the answer is not JSON"
    end
  end
end
