module TestCases
  # "Gemini suggests, the person decides" for the competency test bank (FLOW §7, 17 Oct 2026): from
  # the SAVED brief (position, activities, competencies) the AI proposes questions for the two
  # sections. The proposal is stored as it came (BriefSuggestion, payload "bank") and nothing enters
  # the bank until the HR Admin ticks rows and adds them (TestCases::SaveBank "accept_ai"); the HR
  # Manager approves the bank afterwards. The text sent holds no candidate data, no company name and
  # no salary. Tier MEDIUM (Screening::Config TASK_TIERS :test_bank): drafting a person edits.
  #
  # Ruby, not the model, keeps the rows usable: a row whose activity or competency number is not in
  # the list, whose options are not 2 to 6 distinct texts with one correct answer, or that names a
  # protected attribute (Briefs::Suggest::PROTECTED) is dropped and counted, never shown.
  class DraftBank
    Result = Data.define(:suggestion, :error) do
      def ok? = error.nil?
    end
    PROMPT_VERSION = "test-bank-2026-10-17.1"
    # Asked per call, per section: what the section still lacks to reach its minimum, and at least
    # MIN_ASK, so a full section can still get fresh alternatives. MAX_ASK bounds the reply size.
    MIN_ASK = 2
    MAX_ASK = 12

    SYSTEM = <<~PROMPT.freeze
      You draft questions for a competency test that every applicant to one job of an Indonesian
      employer takes while applying. An HR Admin reviews and edits every question and an HR Manager
      approves the bank before any applicant sees it. Write every text in English.

      Two sections:
      - technical: tests whether the applicant can do one of the job's activities (numbered list).
        Ask about the work itself: a calculation, a decision on given figures, spotting an error,
        the right next step. activity = the NUMBER of the activity it tests.
      - role: tests one of the job's competencies (numbered list) through a short work situation.
        competency = the NUMBER of the competency it tests.
      Spread the questions across the listed activities and competencies; do not test one twice
      before every one has a question.

      Each question is either:
      - multiple_choice: 4 options, exactly one correct; the wrong options are plausible mistakes a
        less able applicant would make; correct = the NUMBER (1-4) of the right option; anchors empty.
      - written: an answer of 3 to 6 sentences; options empty, correct 0; anchor_1, anchor_3 and
        anchor_5 say what an answer rated 1 (falls short), 3 (meets) and 5 (excellent) observably
        contains, countable where possible, so a reviewer can point to it in the answer.
      About two thirds multiple_choice. Each question is answerable in about 2 minutes (written: 4),
      from general knowledge of the work, with any figures it needs stated in the question. Never ask
      about personality, private life or opinions.

      #{Briefs::Suggest::NEVER.strip}
    PROMPT

    ROW = Briefs::Suggest::ROW
    SCHEMA = ROW.call(
      questions: { type: "array", items: ROW.call(
        section: { type: "string", enum: QuestionBank::SECTIONS.keys }, activity: { type: "integer" },
        competency: { type: "integer" }, kind: { type: "string", enum: BankQuestion::KINDS.keys },
        prompt: { type: "string" }, options: { type: "array", items: { type: "string" } }, correct: { type: "integer" },
        anchor_1: { type: "string" }, anchor_3: { type: "string" }, anchor_5: { type: "string" }
      ) }
    ).freeze

    def self.call(job:, actor:, bank: nil) = new(job:, actor:, bank:).call

    def initialize(job:, actor:, bank: nil)
      @job = job
      @actor = actor
      @bank = bank
      @activities = job.activities.to_a
      @competencies = job.competencies.to_a
    end

    def call
      return Result.new(nil, "AI drafting is off: no AI provider is configured.") unless Screening::Config.enabled?
      return Result.new(nil, "Enter the position in step 1 first.") if @job.title.blank?
      return Result.new(nil, "Save the activities in step 2 first; each technical question tests one activity.") if @activities.empty?
      return Result.new(nil, "Save the competencies in step 4 first; each role question tests one competency.") if @competencies.empty?

      reply = Screening::Config.client(:test_bank, job: @job).generate(system: SYSTEM, schema: SCHEMA, content:)
      payload = { "bank" => normalise(JSON.parse(reply.text)) }
      suggestion = BriefSuggestion.create!(job: @job, actor: @actor, model_id: reply.model, prompt_version: PROMPT_VERSION, payload:,
                                           input_tokens: reply.input_tokens, output_tokens: reply.output_tokens, created_at: Time.current)
      Result.new(suggestion, nil)
    rescue JSON::ParserError
      Result.new(nil, "The AI answer could not be read. Try again.")
    rescue Screening::Errors::Transient
      Result.new(nil, "The AI service is busy or unreachable. Try again in a moment.")
    rescue Screening::Errors::Base => e
      Result.new(nil, "AI drafting could not be completed (#{e.detail}).")
    end

    def asked(section)
      have = @bank ? @bank.questions_in(section).size : 0
      minimum = @bank ? @bank.minimum_for(section) : default_minimum(section)
      (minimum - have).clamp(MIN_ASK, MAX_ASK)
    end

    private

    def default_minimum(section)
      (section == "technical" ? QuestionBank::DEFAULT_TECHNICAL_DRAW : QuestionBank::DEFAULT_ROLE_DRAW) * QuestionBank::MIN_FACTOR
    end

    def content
      lines = ["Position: #{@job.title}"]
      lines << "Level: #{@job.golongan_label}" if @job.golongan
      lines << "90-day target: #{@job.success_90d}" if @job.success_90d.present?
      lines << "Activities (numbered):" << @activities.each_with_index.map { |a, i| "#{i + 1}. #{a.description} (output: #{a.output})" }
      lines << "Competencies (numbered):" << @competencies.each_with_index.map { |c, i| "#{i + 1}. #{c.name}#{" (rated 5 when: #{c.anchor_5})" if c.anchor_5.present?}" }
      lines << "Write #{asked('technical')} technical questions and #{asked('role')} role questions."
      lines.flatten.join("\n")
    end

    # Rows become the shape SaveBank reads (link_id = the brief row's id; options as slots with
    # `correct` naming the right slot), so accepting a row runs the same checks as typing it.
    def normalise(data)
      dropped = 0
      rows = Array(data.is_a?(Hash) ? data["questions"] : nil).filter_map do |row|
        next (dropped += 1) && nil unless row.is_a?(Hash)

        clean = clean_row(row)
        dropped += 1 if clean.nil?
        clean
      end
      { "questions" => rows, "dropped" => dropped }
    end

    def clean_row(row)
      section = row["section"].to_s
      kind = row["kind"].to_s
      return unless QuestionBank::SECTIONS.key?(section) && BankQuestion::KINDS.key?(kind)

      # 1-based numbers from the prompt's lists; 0 or a negative number must not wrap to the last row.
      list, number = section == "technical" ? [@activities, row["activity"].to_i] : [@competencies, row["competency"].to_i]
      return unless number.between?(1, list.size)

      link = list[number - 1]

      texts = [row["prompt"], *Array(row["options"]), row["anchor_1"], row["anchor_3"], row["anchor_5"]].map(&:to_s)
      return if row["prompt"].to_s.strip.empty? || texts.any? { |t| t.match?(Briefs::Suggest::PROTECTED) }

      base = { "section" => section, "kind" => kind, "link_id" => link.id.to_s, "prompt" => row["prompt"].to_s.strip,
               "link_text" => section == "technical" ? link.description : link.name }
      kind == "multiple_choice" ? choice_row(base, row) : written_row(base, row)
    end

    # The model's `correct` counts the options AS SENT, blanks included; blank options are dropped
    # only after the right one is found, so a blank never moves the answer key to its neighbour
    # (independent test pass F1, 17 Oct 2026). A correct answer that points at a blank drops the row.
    def choice_row(base, row)
      sent = Array(row["options"]).map { |o| o.to_s.strip }
      right = sent[row["correct"].to_i - 1] if row["correct"].to_i.between?(1, sent.size)
      options = sent.reject(&:empty?)
      return if right.blank?
      return unless options.size.between?(BankQuestion::MIN_OPTIONS, BankQuestion::MAX_OPTIONS) && options.map(&:downcase).uniq.size == options.size

      base.merge("options" => options.each_with_index.to_h { |o, i| [i.to_s, o] }, "correct" => options.index(right).to_s)
    end

    def written_row(base, row)
      anchors = %w[anchor_1 anchor_3 anchor_5].to_h { |k| [k, row[k].to_s.strip] }
      return if anchors.values.any?(&:empty?)

      base.merge(anchors)
    end
  end
end
