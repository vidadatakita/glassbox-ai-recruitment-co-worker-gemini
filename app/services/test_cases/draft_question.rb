module TestCases
  # "Write with AI" in the bank's "Add a question" form (Vida 17 Oct 2026): ONE question for the
  # section, type and brief row the HR Admin chose. The reply fills the same form's fields in place
  # (ai_fill.js); nothing is saved until "Add question", which runs every SaveBank check. Only the
  # position, the chosen activity or competency and its anchors are sent (no applicant data). Rows
  # that do not fit (options not 2-6 distinct, a correct number out of range, a protected attribute,
  # missing anchors) are refused with a sentence, never filled half. Tier MEDIUM (test_bank).
  class DraftQuestion
    Result = Data.define(:fields, :error) do
      def ok? = error.nil?
    end
    PROMPT_VERSION = "test-bank-one-2026-10-17.1"

    SYSTEM = <<~PROMPT.freeze
      You write ONE question for a competency test every applicant to one job of an Indonesian employer
      takes while applying. An HR Admin reviews and edits it, and an HR Manager approves the bank, before
      any applicant sees it. Write in English.
      - A technical question tests the given job activity: a calculation, a decision on given figures,
        spotting an error, the right next step. A role question tests the given competency through a
        short work situation.
      - multiple_choice: prompt; options = 4 options, exactly one correct, the wrong ones plausible
        mistakes; correct = the NUMBER (1-4) of the right option; anchors empty.
      - written: prompt asking for 3 to 6 sentences; options empty, correct 0; anchor_1, anchor_3,
        anchor_5 = what an answer rated 1, 3 and 5 observably contains.
      Answerable in about 2 minutes (written: 4), with any figures it needs stated in the question.
      Never ask about personality, private life or opinions.

      #{Briefs::Suggest::NEVER.strip}
    PROMPT
    SCHEMA = Briefs::Suggest::ROW.call(
      prompt: { type: "string" }, options: { type: "array", items: { type: "string" } }, correct: { type: "integer" },
      anchor_1: { type: "string" }, anchor_3: { type: "string" }, anchor_5: { type: "string" }
    ).freeze

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(job:, actor:, section:, kind:, link_id:)
      @job = job
      @actor = actor
      @section = section.to_s
      @kind = kind.to_s
      @link_id = link_id.to_s
    end

    def call
      return Result.new(nil, Authority.edit_refusal(@actor, @job)) unless Authority.may_edit_bank?(@actor, @job)
      return Result.new(nil, "AI writing is off: no AI provider is configured.") unless Screening::Config.enabled?
      return Result.new(nil, "Choose the section and the type first.") unless QuestionBank::SECTIONS.key?(@section) && BankQuestion::KINDS.key?(@kind)

      link = brief_row
      return Result.new(nil, "Choose what the question tests (#{@section == 'technical' ? 'an activity' : 'a competency'} of this vacancy) first.") if link.nil?

      reply = Screening::Config.client(:test_bank, job: @job).generate(system: SYSTEM, schema: SCHEMA, content: content(link))
      fields = fields_from(JSON.parse(reply.text))
      return Result.new(nil, "The AI question was not usable (#{fields}). Try again or write it yourself.") if fields.is_a?(String)

      Result.new(fields, nil)
    rescue JSON::ParserError
      Result.new(nil, "The AI answer could not be read. Try again.")
    rescue Screening::Errors::Transient
      Result.new(nil, "The AI service is busy or unreachable. Try again in a moment.")
    rescue Screening::Errors::Base => e
      Result.new(nil, "The AI could not write the question (#{e.detail}).")
    end

    private

    # Same "a:" / "c:" link the form sends; the prefix must match the section (ids of the two tables overlap).
    def brief_row
      prefix, id = @link_id.match(/\A([ac]):(\d+)\z/)&.captures
      return if prefix.nil? || (prefix == "a") != (@section == "technical")

      prefix == "a" ? @job.activities.find_by(id:) : @job.competencies.find_by(id:)
    end

    def content(link)
      lines = ["Position: #{@job.title}", "Section: #{@section}", "Type: #{@kind}"]
      if link.is_a?(Activity)
        lines << "Activity tested: #{link.description} (output: #{link.output})"
      else
        lines << "Competency tested: #{link.name}"
        lines << "A strong performer (5): #{link.anchor_5}" if link.anchor_5.present?
      end
      lines.join("\n")
    end

    # Keyed by the form's input names, so the reply fills the inputs in place. Returns a String reason
    # when the row is unusable.
    def fields_from(data)
      return "no data" unless data.is_a?(Hash)

      prompt = data["prompt"].to_s.strip
      texts = [prompt, *Array(data["options"]), data["anchor_1"], data["anchor_3"], data["anchor_5"]].map(&:to_s)
      return "empty question" if prompt.empty?
      return "it mentioned a protected attribute" if texts.any? { |t| t.match?(Briefs::Suggest::PROTECTED) }

      fields = { "bank[prompt]" => prompt }
      if @kind == "multiple_choice"
        sent = Array(data["options"]).map { |o| o.to_s.strip }
        right = sent[data["correct"].to_i - 1] if data["correct"].to_i.between?(1, sent.size)
        options = sent.reject(&:empty?)
        return "options are not 2 to 6 distinct answers" unless options.size.between?(BankQuestion::MIN_OPTIONS, BankQuestion::MAX_OPTIONS) && options.map(&:downcase).uniq.size == options.size
        return "no correct option" if right.blank?

        BankQuestion::MAX_OPTIONS.times { |i| fields["bank[options][#{i}]"] = options[i].to_s }
        fields["bank[correct]"] = options.index(right).to_s
      else
        anchors = %w[anchor_1 anchor_3 anchor_5].to_h { |k| [k, data[k].to_s.strip] }
        return "the three scoring anchors are not all there" if anchors.values.any?(&:empty?)

        anchors.each { |k, v| fields["bank[#{k}]"] = v }
      end
      fields
    end
  end
end
