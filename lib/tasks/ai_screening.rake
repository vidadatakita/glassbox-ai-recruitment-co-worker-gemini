# Operator tasks for S1 AI screening (feature 06).
# None of them prints the API key, a CV of a real candidate, or a response body.
namespace :glassbox do
  namespace :ai do
    desc "Show whether AI screening is on, where the key comes from (never the key), and the model"
    task status: :environment do
      puts "AI screening: #{Screening::Config.enabled? ? 'ON' : 'OFF (AI screening is off)'}"
      puts "Provider:     #{Screening::Config.provider}"
      puts "Key source:   #{Screening::Config.key_source || 'none'}"
      Screening::Config::TIERS.each_key do |tier|
        tasks = Screening::Config::TASK_TIERS.select { |_, t| t == tier }.keys.join(", ")
        puts "Tier #{tier.to_s.upcase}: #{Screening::Config.model_for_tier(tier)} (thinking #{Screening::Config.thinking_for_tier(tier)}) for #{tasks}"
      end
      puts "Known model ids: #{Screening::Config::KNOWN_MODELS.join(', ')}"
      puts "Prompt:       #{Screening::PROMPT_VERSION}"
    end

    desc "ONE real API call on an INVENTED CV, to verify the credentials and the model of one tier (TIER=high|medium|low, default high; costs one request)"
    task smoke: :environment do
      abort "No credentials for provider #{Screening::Config.provider}: set AI_API_KEY (or the service account)." unless Screening::Config.enabled?

      tier = ENV.fetch("TIER", "high").downcase.to_sym
      abort "TIER must be high, medium or low" unless Screening::Config::TIERS.key?(tier)
      task_name = Screening::Config::TASK_TIERS.key(tier)
      rubric = Screening::Sample.rubric
      reply = Screening::Config.client(task_name).judge(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: rubric.payload)
      data = JSON.parse(reply.text)
      ids = data.fetch("criteria").map { |c| c["id"] }
      # The id FROM THE RESPONSE, not the configured one, so a server-side alias cannot hide a mismatch.
      puts "OK. Tier #{tier.to_s.upcase}: configured #{Screening::Config.model_for_tier(tier)}, model that answered: #{reply.model}"
      puts "Criteria judged: #{ids.size} of #{rubric.criteria.size} (#{ids.sort.join(', ')})"
      puts "Tokens: input #{reply.input_tokens}, output #{reply.output_tokens}"
    rescue Screening::Errors::Base => e
      abort "FAILED: #{e.kind} (#{e.detail})."
    end

    # Plan task A9 (Screening::Evaluation): the numbers the README and the deck may claim. Each run
    # writes a Markdown summary and a per-judgement CSV to tmp/evaluation/, named by prompt version,
    # so a prompt change can be compared run against run.
    desc "Agreement and cost check: the 25 invented demo CVs screened by Gemini vs the hand scores (JUDGE=hand: dry run, no model call; THREADS=4; PRICE_INPUT_PER_MTOK and PRICE_OUTPUT_PER_MTOK in USD add the cost per 100 CVs)"
    task eval: :environment do
      dry = ENV["JUDGE"] == "hand"
      abort "No credentials for provider #{Screening::Config.provider}: set AI_API_KEY (or the service account), or run JUDGE=hand." unless dry || Screening::Config.enabled?

      prices = { input: ENV["PRICE_INPUT_PER_MTOK"], output: ENV["PRICE_OUTPUT_PER_MTOK"] }
      prices = prices.values.all?(&:present?) ? prices.transform_values { |v| Float(v) } : nil
      puts "Screening #{Screening::Evaluation.demo_cases.size} invented CVs (#{dry ? 'dry run with the hand scores' : "Tier HIGH, #{Screening::Config.model(:screening)}"}) ..."
      report = Screening::Evaluation.call(judge: (Screening::Evaluation.hand_judge if dry), threads: ENV.fetch("THREADS", 4))
      dir = Rails.root.join("tmp/evaluation")
      FileUtils.mkdir_p(dir)
      base = dir.join("agreement-#{report.prompt_version}-#{dry ? 'dry-run' : 'gemini'}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}")
      File.write("#{base}.md", markdown = report.to_markdown(prices:))
      File.write("#{base}.csv", report.to_csv)
      puts markdown
      puts "Written: #{base}.md and #{base}.csv"
    end

    desc "Count input tokens for one screening request (no generation), on the invented sample CV and rubric"
    task count_tokens: :environment do
      abort "AI is not configured for provider #{Screening::Config.provider}." unless Screening::Config.enabled?

      # Sample only (D51, F09-01): a job's rubric or a candidate's CV is never sent outside the
      # release step. Real figures: screening_results.input_tokens after the first released CVs.
      rubric = Screening::Sample.rubric
      tokens = Screening::Config.client.count_tokens(redacted_cv: Screening::Sample.redacted_cv, rubric_payload: rubric.payload)
      puts "Input tokens for one CV (sample CV, #{rubric.criteria.size} requirements): #{tokens}"
      puts "Real CVs: read screening_results.input_tokens / output_tokens after the first released texts."
    rescue Screening::Errors::Base => e
      abort "FAILED: #{e.kind} (#{e.detail})."
    end
  end

  namespace :retention do
    # UU 27/2022 Pasal 40 / D16 / D32 (feature 09, F09-04): erases every stored copy of the CV text
    # (CandidateErasure: release texts, AI quotes and report text, stage notes, the extracted text,
    # the CV file) of every application whose retention period has ended, whose consent was
    # withdrawn, or that never had consent. The retention period runs from consent_at for
    # consent_retention_days days (the number in the consent text the candidate accepted) - the
    # builder's reading of D32, feature record 09 §8. Prints counts only. Safe to run daily: an
    # erased application has nothing left and is skipped.
    desc "Erase stored CV text at retention end, consent withdrawal or missing consent (prints counts only)"
    task erase_expired: :environment do
      now = Time.current
      counts = Hash.new(0)
      with_text = JobApplication.where.not(cv_text: nil).select(:id)
      with_release = AiRelease.where.not(payload_text: nil).joins(:participation).select("participations.job_application_id")
      with_result = ScreeningResult.where.missing(:screening_result_erasure).joins(:participation).select("participations.job_application_id")
      with_file = ActiveStorage::Attachment.where(record_type: "JobApplication", name: "cv").select(:record_id)
      apps = JobApplication.where(id: with_text).or(JobApplication.where(id: with_release))
                           .or(JobApplication.where(id: with_result)).or(JobApplication.where(id: with_file))
      apps.find_each do |app|
        reason = if app.consent_withdrawn_at then "consent_withdrawn"
                 elsif app.consent_at.nil? || app.status == "no_consent" then "no_consent"
                 elsif app.consent_retention_days && app.consent_at + app.consent_retention_days.days <= now then "retention_expired"
                 end
        next unless reason

        result = CandidateErasure.call(application: app, reason:, note: "glassbox:retention:erase_expired")
        counts[reason] += 1 if result.values.any?(&:positive?)
      end
      puts "Applications erased: #{counts.empty? ? 'none' : counts.map { |k, v| "#{k} #{v}" }.join(', ')}"
    end
  end

  namespace :ai_release do
    desc "Old name of glassbox:retention:erase_expired (kept so existing cron lines keep working)"
    task erase_expired: "glassbox:retention:erase_expired"
  end
end
