module Screening
  # One screening attempt for one S1 participation (blueprint §4.1 steps 3-6, 9; §4.3). Called by
  # ScreenParticipationJob, which owns the retries.
  #
  #   1. CV text: the stored text (extracted earlier or pasted by a consultant), else extract it
  #      from the PDF. No text layer -> cv_unreadable, "CV tidak terbaca"; no API call, no score.
  #   2. D51 release gate (Screening::ReleaseGate): evidence sections only, redaction with the
  #      candidate's own name, residual check, then a reviewer releases the exact text. Until a
  #      release exists the run stops here (:awaiting_release) and NOTHING is sent.
  #   3. Rubric = the brief's requirements (Screening::Rubric). An incomplete rubric is a permanent
  #      failure shown to staff, never a guess.
  #   4. AI call (any provider): the client finds the released, unconsumed AiRelease for the digest,
  #      checks the caller's text is byte-identical to the stored one, and sends the STORED text
  #      (AiClient#judge_released -> #send_released). Errors are classified there.
  #   5. Parse and validate the answer: one entry per requirement, judgement allowed for its tier.
  #      Anything else is Malformed (1 retry, then failed).
  #   6. Quote check per criterion (Screening::QuoteCheck).
  #   7. Score in Ruby (Screening::Score), then in ONE transaction: participation marked attended
  #      and done, a ScoreEntry carrying model id and prompt version, the ScreeningResult, the
  #      attempt row. Then Screening::Finalize, which writes a Decision only when allowed.
  #
  # On any failure NO ScoreEntry and NO ScreeningResult are written (§4.3 "never a default score").
  class Run
    def self.call(participation, attempt:) = new(participation, attempt:).call

    # The §4.3 failed state, after the retries are spent or at once for a permanent failure.
    def self.fail!(participation, error, attempt:)
      participation.reload.update!(screening_state: "screening_failed", screening_failure: error.kind,
                                   screening_failure_detail: error.detail.to_s[0, 200], screening_state_at: Time.current)
      Rails.logger.warn("[screening] participation=#{participation.id} failed kind=#{error.kind} attempt=#{attempt}")
    end

    def initialize(participation, attempt:)
      @participation = participation
      @attempt = attempt
      @application = participation.job_application
      @job = participation.stage.job
    end

    # Returns :done, :cv_unreadable, :awaiting_release or :skipped. Raises Screening::Errors::* for the job's policy.
    def call
      return :skipped unless still_wanted?

      text = cv_text
      return mark_unreadable if text.nil?

      rubric = Rubric.for(@job)
      raise Errors::Permanent.new("rubric", "the vacancy brief is incomplete") if rubric.problems.any?

      names = [@application.candidate&.name]
      # D51 (feature 09): evidence sections only (A), redaction + fail-closed residual check +
      # evidence floor (C), then a person releases the exact text (B). Without a released text
      # nothing is sent: the CV waits in "Menunggu pemeriksaan". See Screening::ReleaseGate.
      gate = ReleaseGate.new(@participation, text:, rubric:, names:, attempt: @attempt)
      release = gate.call
      return :awaiting_release if release.nil?

      begin
        reply = Config.client(:screening, job: @participation.job).judge_released(payload: release.payload_text, sha256: release.payload_sha256)
      rescue Errors::ReleaseMismatch => e
        record_failure(e)
        raise Errors::Permanent.new("release_mismatch", e.detail) unless release.is_a?(AiRelease)

        gate.requeue!(release, e.detail)
        return :awaiting_release
      end
      @release = release
      # flags: the protected categories the model reported, plus AiClient::INSTRUCTION_FLAG.
      judgements, flags = parse(reply.text, rubric, extracted: text, redacted: release.cv_part)
      if (categories = flags - [AiClient::INSTRUCTION_FLAG]).any?
        # Category names only: they tell the redactor's owner which word list missed something.
        Rails.logger.warn("[screening] participation=#{@participation.id} protected_attribute_seen categories=#{categories.join(',')}")
      end
      if flags.include?(AiClient::INSTRUCTION_FLAG)
        # The flag only, never the text: it tells the owner of InjectionCheck's rules that one was missed.
        Rails.logger.warn("[screening] participation=#{@participation.id} instruction_seen")
      end
      score = Score.compute(rubric, judgements)
      persist(rubric, judgements, score, reply, flags)
      Finalize.call(@job)
      :done
    rescue Errors::Base => e
      record_failure(e)
      raise
    rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError => e
      # The CV file is missing or corrupt in storage: nothing a retry can fix. Failed visibly with
      # the error class only (F-04).
      raise record_failure(Errors::Permanent.new("cv_file", e.class.name.demodulize))
    end

    private

    # The participation is still waiting for this job: queued, undecided, and every gate still
    # open (consent can be withdrawn, the key removed, while the job waits in the queue).
    def still_wanted?
      @participation.reload
      return false unless @participation.screening_state == "queued"

      reason = Enqueue.blocked_reason(@participation)
      return true if reason.nil?

      # Gates that closed while waiting (AI switched off, consent withdrawn, application withdrawn,
      # decided meanwhile, ...): the participation returns to "not asked", so it no longer counts
      # under "Dalam antrean" on the job page (test engine run 1, F-07). With the AI off the page
      # then shows "belum aktif"; the other reasons are not screenable at all.
      @participation.update!(screening_state: nil, screening_state_at: Time.current)
      Rails.logger.info("[screening] participation=#{@participation.id} skipped reason=#{reason}")
      false
    end

    def cv_text
      return @application.cv_text if @application.cv_text.present?
      return nil unless @application.cv.attached?

      text = CvText.extract(@application.cv.download)
      @application.update!(cv_text: text, cv_text_source: "pdf", cv_text_at: Time.current) if text
      text
    end

    def mark_unreadable
      ActiveRecord::Base.transaction do
        @participation.update!(screening_state: "cv_unreadable", screening_failure: nil, screening_failure_detail: nil,
                               screening_state_at: Time.current)
        ScreeningAttempt.create!(participation: @participation, attempt: @attempt, outcome: "cv_unreadable",
                                 created_at: Time.current)
      end
      :cv_unreadable
    end

    def record_failure(error)
      ScreeningAttempt.create!(participation: @participation, attempt: @attempt, outcome: "failed",
                               error_kind: error.kind, detail: error.detail.to_s[0, 200], created_at: Time.current)
      error
    end

    # Returns { "R12" => { "judgement", "quote", "verified" } } for every criterion, or raises
    # Malformed. Structured output makes the SHAPE reliable; the per-job rules (every id exactly
    # once, a judgement allowed for the tier) are checked here. "quote" holds the criterion's
    # passages joined (QuoteCheck.check); "verified" is true only when every passage was found.
    TOP_KEYS = %w[criteria protected_attribute_seen protected_attribute_categories instruction_seen report].freeze
    # "quote": the one-passage shape up to prompt s1-2026-10-16.3, read the same way (QuoteCheck.passages_of).
    CRITERION_KEYS = %w[id quotes judgement quote].freeze

    def parse(text, rubric, extracted:, redacted:)
      @schema_breach = false
      data = JSON.parse(text)
      entries = data.is_a?(Hash) ? data["criteria"] : nil
      raise Errors::Malformed.new("malformed", "the answer format does not match") unless entries.is_a?(Array)

      by_id = {}
      entries.each do |entry|
        id = entry.is_a?(Hash) ? entry["id"].to_s : ""
        criterion = rubric.by_key[id]
        raise Errors::Malformed.new("malformed", "unknown requirement") if criterion.nil?
        raise Errors::Malformed.new("malformed", "a requirement was judged twice") if by_id.key?(id)

        judgement = entry["judgement"].to_s
        unless Rubric::JUDGEMENTS.fetch(criterion.tier).include?(judgement)
          raise Errors::Malformed.new("malformed", "the judgement does not match the requirement tier")
        end

        @schema_breach = true if (entry.keys - CRITERION_KEYS).any?
        by_id[id] = { "judgement" => judgement, **QuoteCheck.check(entry, judgement:, extracted:, redacted:) }
      end
      missing = rubric.criteria.map(&:key) - by_id.keys
      raise Errors::Malformed.new("malformed", "#{missing.size} requirement(s) not judged") if missing.any?

      # F-33: a key outside the schema (top level or per criterion) means the answer was not held to
      # the schema, so its protected-attribute discipline cannot be trusted either. Chosen: keep the
      # judgements (they were validated one by one) but route the result to the reviewer as
      # "protected_attribute / other". Rejected: treating it as malformed (retry, then fail), which
      # pays for a second call and loses a usable judgement when the breach is harmless. The extra
      # values are never stored or logged: only the known fields are read.
      @schema_breach = true if (data.keys - TOP_KEYS).any?
      # Feature 08: the optional report block. Its own shape check; a malformed block is a breach
      # like an unknown key, and nothing from it is stored.
      report = ReportFields.parse(data["report"], extracted:, redacted:)
      @schema_breach = true if report.breach
      @report_attributes = report.attributes
      categories = protected_categories(data)
      categories = (categories + ["other"]).uniq if @schema_breach
      categories += [AiClient::INSTRUCTION_FLAG] if instruction_seen?(data)
      [by_id, categories]
    rescue JSON::ParserError
      raise Errors::Malformed.new("malformed", "jawaban bukan JSON")
    end

    # The model's instruction flag (prompt s1-2026-10-16.4): text in the CV written as an
    # instruction to the AI. Seen -> AiClient::INSTRUCTION_FLAG joins the stored categories, so the
    # review queue holds the result for a person exactly as for a protected attribute (the review
    # reason stays "protected_attribute", the one value the database allows for a model flag; the
    # report names the instruction). Present but not false (true, "yes", null) is read as seen:
    # fail safe. Missing is read as not seen: answers in the shape up to .3 had no such flag, and
    # Screening::InjectionCheck still holds every CV whose instruction its rules recognise before
    # any call.
    def instruction_seen?(data) = data.key?("instruction_seen") && data["instruction_seen"] != false

    # The model's protected-attribute flag (ADR 0004 line 3). Fail safe, not fail hard: a flag that
    # is missing or not in the schema's shape is read as "seen, category other", so the result goes
    # to the reviewer instead of being trusted (and the judgements are still usable). A true flag
    # with no category is also "other".
    def protected_categories(data)
      seen = data["protected_attribute_seen"]
      categories = data["protected_attribute_categories"]
      valid = [true, false].include?(seen) && categories.is_a?(Array) &&
              categories.all? { |c| AiClient::PROTECTED_CATEGORIES.include?(c) }
      return ["other"] unless valid
      # F-29: only "not seen, no categories" is trusted. "Not seen" WITH categories, or "seen" with
      # none, contradicts itself: the reviewer looks.
      return [] if seen == false && categories.empty?
      return ["other"] if categories.empty?

      categories.uniq
    end

    def persist(rubric, judgements, score, reply, protected_categories = [])
      now = Time.current
      discarded = false
      ActiveRecord::Base.transaction do
        # The job row lock serialises pass numbering for the 10% sample (Screening::ReviewSample).
        @job.lock!
        @participation.lock!
        @application.lock!
        # Every gate again, under the locks, AFTER the call (test engine run 2, F-15): consent or the
        # application may have been withdrawn while the request was in flight (UU PDP: nothing is
        # stored for a withdrawn consent), another run may have finished, or a person decided.
        # The AI being switched off meanwhile does not void an answer already received.
        reason = Enqueue.blocked_reason(@participation)
        unless @participation.screening_state == "queued" && (reason.nil? || reason == :ai_off)
          Rails.logger.info("[screening] participation=#{@participation.id} result discarded: #{reason || 'no longer queued'}")
          discarded = true
          raise ActiveRecord::Rollback
        end

        # A submitted CV is the candidate's attendance at S1; ScoreEntry and a threshold Decision
        # both require "attended" (rule 5, feature 01).
        @participation.update!(attendance: "attended") unless @participation.attendance == "attended"
        entry = score_entry(score, reply, now)
        outcome = Score.outcome(wajib_met: score.wajib_met, score: score.score, threshold: @participation.stage.threshold)
        ordinal, sampled = sample_for(outcome)
        ScreeningResult.create!(
          participation: @participation, score_entry: entry, rubric_digest: rubric.digest, model_id: reply.model,
          prompt_version: PROMPT_VERSION, judgements: criteria_rows(rubric, judgements), score: score.score,
          wajib_met: score.wajib_met, unverified_count: score.unverified_count, bonus_points: score.bonus_points,
          bonus_possible: score.bonus_possible, pass_ordinal: ordinal, sampled:, input_tokens: reply.input_tokens,
          output_tokens: reply.output_tokens, protected_attribute_categories: protected_categories, created_at: now,
          ai_release: (@release if @release.is_a?(AiRelease)), **(@report_attributes || {})
        )
        ScreeningAttempt.create!(participation: @participation, attempt: @attempt, outcome: "succeeded", created_at: now)
        @participation.update!(screening_state: "done", screening_failure: nil, screening_failure_detail: nil,
                               screening_state_at: now)
      end
      # A gate closed during the call: the participation leaves the queue ("not asked"), like a
      # gate closed before the call (F-07).
      if discarded && @participation.reload.screening_state == "queued"
        @participation.update!(screening_state: nil, screening_state_at: Time.current)
      end
    end

    # A re-screening (after a rubric change) corrects the previous AI entry the append-only way: a
    # new row that supersedes it, with the reason (feature 01).
    def score_entry(score, reply, now)
      previous = @participation.score_entries.current.order(:id).last
      ScoreEntry.create!(
        participation: @participation, value: score.score, ratings: {}, entered_by_id: AI_ACTOR_ID,
        event_at: @application.created_at, entered_at: now, model_id: reply.model, prompt_version: PROMPT_VERSION,
        supersedes: previous, correction_reason: previous ? "AI screening repeated (rubric or CV changed)" : nil
      )
    end

    def sample_for(outcome)
      return [nil, false] unless outcome.outcome == :pass

      # update_columns: a system field, set once; the job's own validations are not this code's to run.
      @job.update_columns(screening_sample_seed: ReviewSample.new_seed) if @job.screening_sample_seed.blank?
      ordinal = ScreeningResult.joins(participation: :stage).where(stages: { job_id: @job.id })
                               .where.not(pass_ordinal: nil).maximum(:pass_ordinal).to_i + 1
      [ordinal, ReviewSample.sampled?(seed: @job.screening_sample_seed, ordinal:)]
    end

    def criteria_rows(rubric, judgements)
      rubric.criteria.map do |c|
        j = judgements.fetch(c.key)
        { "requirement_id" => c.requirement_id, "key" => c.key, "tier" => c.tier, "text" => c.text,
          "weight" => c.weight, "judgement" => j["judgement"], "quote" => j["quote"], "verified" => j["verified"] }
      end
    end
  end
end
