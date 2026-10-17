# frozen_string_literal: true

module Briefs
  # AI Builder Cup step 01 ("Gemini suggests, the person decides"): from the job title, level,
  # employment type and placements, the AI proposes the 90-day target, 5-8 activities and the
  # three-tier requirements. The proposal is stored as it came (BriefSuggestion) and only fills the
  # wizard's form; nothing in the brief changes until HR or the consultant presses Save, which
  # records the change like any other save (SaveStep). This reverses the earlier "typed by hand, no
  # AI drafting" rule for the brief; docs/features/03-job-form.md records the change.
  #
  # The text sent holds no candidate data and no company name or salary: only what the title and
  # the level say about the work. Whatever provider AI_PROVIDER names is used, with the "text"
  # task's model and thinking (Screening::Config, AI_MODEL_TEXT / AI_THINKING_TEXT).
  #
  # Ruby, not the model, makes the numbers add up: activity shares and sebaiknya weights are scaled
  # to exactly 100. A proposed line that names a protected attribute (age, gender, religion,
  # marital status, appearance, ethnicity) is dropped and counted, never shown as a suggestion.
  #
  # Step 4 (kind :competencies) proposes the competency map instead: name, layer, assessing stage,
  # rating anchors 1/3/5 and, for the interview stages, the questions. It is built from what the
  # person already SAVED in steps 2 and 3 and from the chosen package's stages; package, weights
  # and thresholds stay the person's choice.
  class Suggest
    Result = Data.define(:suggestion, :error) do
      def ok? = error.nil?
    end

    # .2 (16 Oct, accuracy pass): the brief is written for the CV screening that judges against it
    # (one checkable item per requirement, cv_evidence as a CV line would say it, must-haves only for
    # what day one needs), the screening standard's stand-ins for protected attributes are named in
    # every prompt, and the test and ad prompts say what makes a case and an ad usable.
    PROMPT_VERSION = "brief-2026-10-16.2"
    COMPETENCY_PROMPT_VERSION = "competencies-2026-10-16.2"
    TEST_PROMPT_VERSION = "test-case-2026-10-16.2"
    AD_PROMPT_VERSION = "job-ad-2026-10-16.2"
    # The screening standard's prohibitions (FLOW §8.6), shared by the four drafting prompts.
    NEVER = <<~TEXT.freeze
      Never require or mention age, gender, religion, ethnicity or region of origin, marital status,
      pregnancy or children, appearance, height or weight, general health, disability not tested by
      the work, family data, political views or union membership. Never use their stand-ins either:
      "fresh graduate" (required or excluded), a maximum number of years of experience, a
      graduation-year limit, "young", "energetic", "native speaker", "presentable", "good looking",
      a photo, a family card or a bank account at application.
    TEXT
    MAX_COMPETENCIES = BriefForm::COMPETENCY_SLOTS
    LIMITS = { "wajib" => 6, "sebaiknya" => 6, "nilai_tambah" => 4 }.freeze # BriefForm::REQUIREMENT_SLOTS
    MAX_ACTIVITIES = BriefForm::ACTIVITY_SLOTS
    MAX_KNOCKOUTS = 3
    # A suggested line that names a protected attribute is dropped before the person sees it.
    # Indonesian and English (English alternatives added 16 Oct 2026 for the English demo; the
    # Indonesian words are unchanged). Named attributes only; proxies are the discrimination test's job.
    PROTECTED = /\b(usia|umur|berumur|tahun ke bawah|pria|wanita|laki-laki|perempuan|jenis kelamin|gender|agama|muslim|muslimah|kristen|katolik|hindu|buddha|menikah|lajang|single|status pernikahan|berpenampilan|penampilan menarik|good looking|tinggi badan|berat badan|suku bangsa|etnis|(?:maximum|max\.?|under|below)\s+(?:age\s+)?\d{2}|\d{2}\s*years?\s+old|age\s+(?:limit|range|between|under|below|max)|young|male|female|men\s+only|women\s+only|religion|christian|catholic|protestant|buddhist|islamic|married|unmarried|marital\s+status|pregnant|attractive|presentable|well[- ]groomed|body\s+(?:size|shape|weight|height)|(?:minimum|min\.?|maximum|max\.?)\s+(?:height|weight)|ethnicity|ethnic|race(?!\s+condition)|descent)\b/i

    SYSTEM = <<~PROMPT.freeze
      You draft a job brief for an Indonesian employer. A recruiter reviews and edits every line
      before it is used, so be concrete and realistic for the Indonesian labour market. Write every
      text in English. The brief drives what follows: every CV is judged against its requirements,
      quote by quote, and the technical test is built from its activities.

      From the job title and level, return:
      - success_90d: one or two sentences: what the right person has visibly achieved after 90 days
        on the job. Observable results with a deliverable, a deadline or a quality level, not
        personality.
      - activities: 5 to 8 main activities. description = what the person does (a verb and its
        object); output = the work product it delivers; share_percent = share of working time,
        whole numbers summing to 100.
      - requirements, each checkable from a CV:
        tier "wajib" (must-have, 2 to 4 lines): only what the work cannot be done without from day
        one, such as a minimum education level, a licence or certificate the work needs, or core
        experience. Give 2 or 3 of them a yes/no knockout question in "knockout" that any applicant
        can answer truthfully about themselves (e.g. "Do you hold a valid SIM C driving licence?"),
        else "".
        tier "sebaiknya" (should-have, 3 to 5 lines, "weight" whole numbers summing to 100, the
        largest for what the main activities need most).
        tier "nilai_tambah" (nice-to-have, 1 to 3 lines).
        For each line, "text" is ONE skill, tool, duty, qualification or certificate, specific
        enough to check (name the tool, the duty or the level, e.g. "Experience preparing bank
        reconciliations"), never a personality trait such as "honest" or "hard-working". Education
        uses Indonesian levels with the English, e.g. "At least a D3 (diploma) in Accounting".
        "cv_evidence" is what a line of a CV would say that proves it, e.g. "Bank reconciliations
        named in the work history". Use weight 0 and an empty knockout where they do not apply.

      #{NEVER.strip}
      Requirements are about skills, experience, education, licences and certifications only.
    PROMPT

    ROW = ->(props) { { type: "object", additionalProperties: false, required: props.keys.map(&:to_s), properties: props } }
    SCHEMA = ROW.call(
      success_90d: { type: "string" },
      activities: { type: "array", items: ROW.call(description: { type: "string" }, output: { type: "string" }, share_percent: { type: "integer" }) },
      requirements: { type: "array", items: ROW.call(
        tier: { type: "string", enum: LIMITS.keys }, text: { type: "string" }, cv_evidence: { type: "string" },
        weight: { type: "integer" }, knockout: { type: "string" }
      ) }
    ).freeze

    COMPETENCY_SYSTEM = <<~PROMPT.freeze
      You draft the competency map for one job of an Indonesian employer. A recruiter reviews and
      edits every line before it is used. Write every text in English.

      Return 4 to 8 competencies, from the job's activities and requirements. For each:
      - name: short competency name.
      - layer: one of the given layer codes. Cover every layer listed as required at least once.
      - stage_code: one of the given stages, the one that best assesses it (a CV shows knowledge and
        experience; a technical test shows skill; an interview shows judgement, teaching and integrity).
      - anchor_1, anchor_3, anchor_5: what the person observably DOES and its result at rating 1
        (falls short), 3 (meets the job) and 5 (excellent), each one sentence that two assessors
        would apply the same way. Never personality or attitude words.
      - questions: for stages S3 and S5 (interviews), 2 or 3 behavioural questions asking for a real
        past example (the situation, what the person did, the result), one per line; for other
        stages an empty string.

      #{NEVER.strip}
    PROMPT

    COMPETENCY_SCHEMA = ROW.call(
      competencies: { type: "array", items: ROW.call(
        name: { type: "string" }, layer: { type: "string", enum: Competency::LAYERS.keys },
        stage_code: { type: "string", enum: Competency::STAGE_CODES }, anchor_1: { type: "string" },
        anchor_3: { type: "string" }, anchor_5: { type: "string" }, questions: { type: "string" }
      ) }
    ).freeze

    # Step 5 (kind :test): the technical test drafted from the saved activities. The consultant still
    # uploads the case file (approval needs one) and HR still approves the version.
    TEST_SYSTEM = <<~PROMPT.freeze
      You draft a technical test (a short practical case) for one job of an Indonesian employer. A
      consultant reviews and edits it, and HR approves it, before any candidate sees it. Write every
      text in English.

      Return:
      - instructions: what the candidate must do and what to hand in, 3 to 6 sentences, for a case
        that fits in the time limit and is solved from the case file alone, the way the work is
        done on the job. Refer to "the case file" for the data the candidate works on.
      - time_limit_minutes: whole minutes, 20 to 60.
      - answer_types: the file types the answer is handed in as, from the given list.
      - criteria: 2 to 5 rubric lines. activity = the NUMBER of the job activity it tests (from the
        numbered list); name = short criterion name; weight = whole numbers summing to 100;
        anchor_1, anchor_3, anchor_5 = what an answer rated 1 (falls short), 3 (meets) and 5
        (excellent) observably contains, countable where possible (e.g. "finds all three errors
        with the correct figures"), so a reviewer can point to it in the answer. Never personality.

      #{NEVER.strip}
    PROMPT

    TEST_SCHEMA = ROW.call(
      instructions: { type: "string" }, time_limit_minutes: { type: "integer" },
      answer_types: { type: "array", items: { type: "string", enum: TechnicalTestCase::ANSWER_TYPES.keys } },
      criteria: { type: "array", items: ROW.call(
        activity: { type: "integer" }, name: { type: "string" }, weight: { type: "integer" },
        anchor_1: { type: "string" }, anchor_3: { type: "string" }, anchor_5: { type: "string" }
      ) }
    ).freeze

    # Step "ad" (AI Builder Cup step 02): the job ad, written from the SAVED brief. Inclusive by
    # instruction; the saved text is then checked anyway (Briefs::AdCheck) and HR approves it.
    AD_SYSTEM = <<~PROMPT.freeze
      You write a job ad in English for an Indonesian employer, from the job brief given. A
      recruiter edits and approves it before candidates see it. Plain, friendly and concrete; no
      emojis, no hype. Structure, as plain text with these headings on their own lines and "- "
      bullets:
      About this role (2-3 sentences: the role and what success after 90 days looks like)
      What you will do (the activities)
      What we are looking for (the must-have and should-have requirements, in candidate-friendly words)
      Nice to have (the nice-to-haves, if any)
      Location and work arrangement (location, employment type, work arrangement; the salary range
      only if it is given)
      Never write the company name (it is shown separately). Do not invent benefits, salary,
      requirements or facts that are not in the brief; keep every requirement's meaning and level.
      #{NEVER.strip}
    PROMPT
    AD_SCHEMA = ROW.call(ad_text: { type: "string" }).freeze

    KINDS = {
      ad: [AD_SYSTEM, AD_SCHEMA, AD_PROMPT_VERSION],
      brief: [SYSTEM, SCHEMA, PROMPT_VERSION],
      competencies: [COMPETENCY_SYSTEM, COMPETENCY_SCHEMA, COMPETENCY_PROMPT_VERSION],
      test: [TEST_SYSTEM, TEST_SCHEMA, TEST_PROMPT_VERSION]
    }.freeze

    # step "2"/"3": the brief (target, activities, requirements); "4": the competency map; "5": the
    # technical test.
    MAX_INSTRUCTION = 1000

    # instruction: the person's own optional wish ("casual tone, shorter"); draft: for the ad,
    # the text now in the form, to rewrite rather than start over. Both are staff text, never
    # candidate data; the system prompt's rules (no protected attributes) still win.
    def self.call(job:, actor:, step: "2", instruction: nil, draft: nil) = new(job:, actor:, step:, instruction:, draft:).call

    def initialize(job:, actor:, step: "2", instruction: nil, draft: nil)
      @job = job
      @actor = actor
      @instruction = instruction.to_s.strip[0, MAX_INSTRUCTION].presence
      @draft = draft.to_s.strip[0, 20_000].presence
      @kind = { "4" => :competencies, "5" => :test, "ad" => :ad }.fetch(step.to_s, :brief)
      @competencies = @kind == :competencies
    end

    def call
      return Result.new(nil, "AI advice is off: no AI provider is configured.") unless Screening::Config.enabled?
      return Result.new(nil, "Enter the position in step 1 first.") if @job.title.blank?
      if @competencies && @job.activities.empty? && @job.requirements.empty?
        return Result.new(nil, "Save the activities (step 2) and requirements (step 3) first; the competencies are built from both.")
      end
      return Result.new(nil, "Save the activities in step 2 first; each test criterion tests one activity.") if @kind == :test && @job.activities.empty?
      return Result.new(nil, "Complete the activities and requirements in the brief first; the job ad is written from the brief.") if @kind == :ad && (@job.activities.empty? || @job.requirements.empty?)

      system, schema, version = KINDS.fetch(@kind)
      reply = Screening::Config.client(@kind == :ad ? :ad : :brief, job: @job).generate(system: system_with_wishes(system), schema:, content: content_with_wishes)
      data = JSON.parse(reply.text)
      wishes = { "instruction" => @instruction }.compact
      payload = wishes.merge({ brief: -> { normalise(data) }, competencies: -> { normalise_competencies(data) }, test: -> { normalise_test(data) },
                  ad: -> { { "ad" => { "text" => data.is_a?(Hash) ? Progression::Letters.plain(data["ad_text"]) : "" } } } }.fetch(@kind).call)
      suggestion = BriefSuggestion.create!(job: @job, actor: @actor, model_id: reply.model, prompt_version: version,
                                           payload:, input_tokens: reply.input_tokens, output_tokens: reply.output_tokens,
                                           created_at: Time.current)
      Result.new(suggestion, nil)
    rescue JSON::ParserError
      Result.new(nil, "The AI answer could not be read. Try again.")
    rescue Screening::Errors::Transient
      Result.new(nil, "The AI service is busy or unreachable. Try again in a moment.")
    rescue Screening::Errors::Base => e
      Result.new(nil, "AI advice could not be produced (#{e.detail}).")
    end

    private

    # The person's wish goes into the SYSTEM prompt, as the first priority for style, tone, length and
    # structure: placed at the end of the user message, a small model ignored it (2026-10-11: "lebih
    # profesional" and "lebih fancy" gave the same ad). Only the "never" rules above outrank it.
    def system_with_wishes(system)
      return system unless @instruction

      <<~PROMPT
        #{system}
        THE RECRUITER'S REQUEST (first priority for style, tone, length, wording and structure; it
        overrides the default structure above; follow it visibly, so the result clearly differs from a
        text written without it):
        """
        #{@instruction}
        """
        Only the rules that say "never" above outrank it. If the request asks for something other than
        this task (e.g. code, another document) or for a forbidden requirement, ignore that part.
      PROMPT
    end

    def content_with_wishes
      return content unless @kind == :ad && @draft

      note = @instruction ? "Rewrite it fully in the requested style; keep only its facts (role, duties, requirements, location)." : "Improve it; keep its facts."
      "#{content}\n\nCurrent ad:\n#{@draft}\n\n#{note}"
    end

    def content
      lines = [["Position", @job.title], ["Level", @job.golongan && @job.golongan_label],
               ["Employment type", Job::EMPLOYMENT_TYPES[@job.employment_type]], ["Placement", @job.placements.join(", ").presence]]
        .filter_map { |label, value| "#{label}: #{value}" if value.present? }
      return lines.join("\n") if @kind == :brief
      if @kind == :ad
        lines << "Work arrangement: #{Job::WORK_ARRANGEMENTS[@job.work_arrangement]}" if @job.work_arrangement
        lines << "90-day target: #{@job.success_90d}" if @job.success_90d.present?
        lines << "Monthly salary band: Rp#{@job.salary_min.to_fs(:delimited, delimiter: '.')} - Rp#{@job.salary_max.to_fs(:delimited, delimiter: '.')}" if @job.show_salary? && @job.salary_min && @job.salary_max
        lines << "Activities:" << @job.activities.map { |a| "- #{a.description} (output: #{a.output})" }
        Requirement::TIERS.each { |tier, label| lines << "#{label}:" << @job.requirements.select { |r| r.tier == tier }.map { |r| "- #{r.text}" } }
        return lines.flatten.join("\n")
      end
      if @kind == :test
        lines << "Allowed answer file types: #{TechnicalTestCase::ANSWER_TYPES.keys.join(', ')}"
        lines << "Activities (numbered):" << @job.activities.each_with_index.map { |a, i| "#{i + 1}. #{a.description} (output: #{a.output})" }
        lines << "Requirements:" << @job.requirements.map { |r| "- [#{Requirement::TIERS[r.tier]}] #{r.text}" }
        return lines.flatten.join("\n")
      end

      lines << "Stages run: #{stages.map { |c| "#{c} #{StagePlan::LABELS[c]}" }.join(', ')}"
      lines << "Competency layers: #{Competency::LAYERS.map { |c, l| "#{c} #{l}" }.join(', ')}"
      lines << "Layers required for this level: #{Coverage.required(@job.golongan).join(', ')}" if @job.golongan
      lines << "Activities:" << @job.activities.map { |a| "- #{a.description} (output: #{a.output})" }
      lines << "Requirements:" << @job.requirements.map { |r| "- [#{Requirement::TIERS[r.tier]}] #{r.text}" }
      lines.flatten.join("\n")
    end

    # The chosen package's scored stages; before a package is chosen, the recommended default.
    def stages
      package = @job.package || (@job.golongan && PackageAdvisor.default_choice(@job.golongan))
      package ? StagePlan.scored_codes(package) : Competency::STAGE_CODES
    end

    # A stage outside the package, or an interview the model gave no questions for, is replaced: by
    # the package's interview when there are questions, else by the CV screening (an interview with
    # no questions fails BriefCheck).
    # Duplicate names keep the first; at most the form's slot count.
    def normalise_competencies(data)
      raise JSON::ParserError, "not an object" unless data.is_a?(Hash)

      fields = %w[name anchor_1 anchor_3 anchor_5 questions]
      interview = (stages & Competency::INTERVIEW_STAGES).last
      dropped = 0
      rows = Array(data["competencies"]).grep(Hash).filter_map do |c|
        row = c.slice(*fields).transform_values { |v| v.to_s.strip }
        next if row["name"].empty?
        next (dropped += 1) && nil if fields.any? { |f| row[f].match?(PROTECTED) }

        row["layer"] = Competency::LAYERS.key?(c["layer"]) ? c["layer"] : nil
        asked = row["questions"].present?
        row["stage_code"] = c["stage_code"] if stages.include?(c["stage_code"]) && (asked || !Competency::INTERVIEW_STAGES.include?(c["stage_code"]))
        row["stage_code"] ||= (asked && interview) || (stages.include?("S1") ? "S1" : interview || stages.last)
        row["questions"] = "" unless Competency::INTERVIEW_STAGES.include?(row["stage_code"])
        row
      end
      { "competencies" => rows.uniq { |r| r["name"].downcase }.first(MAX_COMPETENCIES), "dropped" => dropped }
    end

    def normalise(data)
      raise JSON::ParserError, "not an object" unless data.is_a?(Hash)

      dropped = 0
      clean = lambda do |row, *keys|
        next true unless keys.any? { |k| row[k].to_s.match?(PROTECTED) }

        dropped += 1
        false
      end
      activities = Array(data["activities"]).grep(Hash).map { |a| a.slice("description", "output", "share_percent").transform_values { |v| v.is_a?(String) ? v.strip : v } }
                       .select { |a| a["description"].present? && clean.call(a, "description", "output") }.first(MAX_ACTIVITIES)
      scale!(activities, "share_percent")

      knockouts = @job.persisted? ? @job.knockout_questions.where(requirement_id: nil).count : 0 # legacy questions use the quota too
      requirements = LIMITS.flat_map do |tier, limit|
        rows = Array(data["requirements"]).grep(Hash).select { |r| r["tier"] == tier && r["text"].present? && clean.call(r, "text", "cv_evidence", "knockout") }.first(limit)
        rows = rows.map do |r|
          knockout = tier == "wajib" && knockouts < MAX_KNOCKOUTS ? r["knockout"].to_s.strip.presence : nil
          knockouts += 1 if knockout
          { "tier" => tier, "text" => r["text"].to_s.strip, "cv_evidence" => r["cv_evidence"].to_s.strip,
            "weight" => (tier == "sebaiknya" ? r["weight"].to_i : nil), "knockout" => knockout }
        end
        scale!(rows, "weight") if tier == "sebaiknya"
        rows
      end
      { "success_90d" => data["success_90d"].to_s.strip, "activities" => activities, "requirements" => requirements, "dropped" => dropped }
    end

    # Activity numbers become activity ids (an unknown number drops the criterion), weights sum to
    # 100, the time limit stays within 1-60 minutes, at most the form's criteria slots.
    def normalise_test(data)
      raise JSON::ParserError, "not an object" unless data.is_a?(Hash)

      activities = @job.activities.to_a
      fields = %w[name anchor_1 anchor_3 anchor_5]
      dropped = 0
      criteria = Array(data["criteria"]).grep(Hash).filter_map do |c|
        activity = activities[c["activity"].to_i - 1] if c["activity"].to_i.positive?
        row = c.slice(*fields).transform_values { |v| v.to_s.strip }
        next if activity.nil? || row["name"].to_s.empty?
        next (dropped += 1) && nil if fields.any? { |f| row[f].to_s.match?(PROTECTED) }

        row.merge("activity_id" => activity.id, "weight" => c["weight"].to_i)
      end.first(TestCases::SaveVersion::CRITERIA_SLOTS)
      scale!(criteria, "weight")
      minutes = data["time_limit_minutes"].to_i
      minutes = TechnicalTestCase::DEFAULT_TIME_LIMIT unless (1..TechnicalTestCase::MAX_TIME_LIMIT).cover?(minutes)
      instructions = data["instructions"].to_s.strip
      if instructions.match?(PROTECTED)
        dropped += 1
        instructions = ""
      end
      { "test" => { "instructions" => instructions, "time_limit_minutes" => minutes,
                    "answer_types" => Array(data["answer_types"]) & TechnicalTestCase::ANSWER_TYPES.keys, "criteria" => criteria },
        "dropped" => dropped }
    end

    # Whole numbers summing to exactly 100, in proportion to what the model gave (largest remainder).
    # Equal shares when the model gave none.
    def scale!(rows, key)
      return if rows.empty?

      raw = rows.map { |r| [r[key].to_i, 0].max }
      raw = Array.new(rows.size, 1) if raw.sum.zero?
      exact = raw.map { |v| Rational(v * 100, raw.sum) }
      shares = exact.map(&:floor)
      (100 - shares.sum).times { |i| shares[exact.each_with_index.sort_by { |e, j| [-(e - e.floor), j] }[i % rows.size][1]] += 1 }
      rows.each_with_index { |r, i| r[key] = shares[i] }
    end
  end
end
