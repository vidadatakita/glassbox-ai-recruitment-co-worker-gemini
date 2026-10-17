# frozen_string_literal: true

module Briefs
  # Screening standard item (FLOW §8.11, Appendix D): the discrimination test run on EVERY
  # requirement of the vacancy brief, before the ad. For each requirement the answer is one of
  #   keep     the requirement is task-related and testable from a CV or a test;
  #   replace  it touches a protected attribute or a proxy for one, and a neutral wording exists
  #            (returned in "replacement");
  #   delete   it is not about the work at all.
  # with a one-sentence reason. The HR owner accepts or rejects each line on the brief screen; this
  # service decides nothing and stores nothing: it returns the lines.
  #
  # Two passes, as in AdCheck: the rule table first (a protected attribute NAMED in the text; same
  # rules as the ad scan, in Indonesian and English), then the AI for what the rules cannot see
  # (proxies such as "fresh graduate", "native speaker", "energetic young team"; and whether the
  # line is testable at all). A rule hit is final for that line ("replace" with the rule's reason;
  # the AI's replacement wording is used when it gave one) so the AI can never talk a named
  # attribute back into the brief. If the AI is off or fails, the rule lines stand and the others
  # come back as "keep" with source "rule" and a reason that says the AI did not run, so the screen
  # can show that the test was partial.
  #
  # Each line: { "id" => "R<id>", "text", "verdict", "reason", "replacement", "source" => "rule" | "ai" }.
  # Structure of the standard's Appendix D (task-related? testable? protected attribute?); the
  # standard's own wording is pasted in by the team later (docs/builder2/appendix-D.md).
  module DiscriminationCheck
    # .2 (16 Oct, accuracy pass): the protected list is the screening standard's full §8 table (region
    # of origin, politics, union, photo, family card, bank account, experience caps and graduation
    # years added), bona fide requirements are named so they are kept, and the reason is generated
    # BEFORE the verdict (schema key order).
    PROMPT_VERSION = "requirement-check-2026-10-16.2"
    VERDICTS = %w[keep replace delete].freeze

    AI_SYSTEM = <<~PROMPT
      You run a discrimination test on the requirements of a job brief for an Indonesian employer,
      following the structure of the employer's screening standard (Appendix D). For EACH
      requirement answer three questions: is it related to the tasks of the job? can it be tested
      from a CV, a work-sample test or an interview? does it name, or stand in for, a protected
      attribute?
      Protected attributes: age; gender; religion; ethnicity, race, descent or region of origin;
      marital status, pregnancy or children; appearance, height or weight; disability or health
      not needed for the work; family data; political views; union membership.
      Stand-ins (proxies) for them: "fresh graduate" (required or excluded), a maximum number of
      years of experience, a graduation-year limit, "young", "energetic", "native speaker",
      "presentable", "good looking", "physically and mentally healthy" without a task, a photo, a
      family card or a bank account asked for at application.
      Requirements that ARE about the work are kept: a minimum education level, a licence or
      certificate the work needs, a minimum number of years of experience, a named tool or skill,
      a language at a stated level ("fluent English"), willingness to work shifts, travel or work
      on site, and a physical ability when the requirement names the task that needs it ("able to
      lift 20 kg boxes in the warehouse").
      Return one entry per requirement, in the order given, with its id exactly as given:
      - reason: one sentence; for "replace" and "delete" it names the attribute, stand-in or
        problem.
      - verdict: "keep" (task-related, testable, no protected attribute or stand-in); "replace"
        (task-related but worded through a protected attribute or a stand-in); "delete" (not
        related to the work, or not testable at all).
      - replacement: for "replace", the same requirement in neutral, testable wording that keeps
        what the work needs (e.g. "able to work rotating shifts" instead of "young and
        energetic"); otherwise "".
      Write every sentence in English. Judge the wording only; never guess who will apply.
    PROMPT
    # Key order is generation order (see Screening::AiClient::SCHEMA): the reason before the verdict.
    LINE = Suggest::ROW.call(id: { type: "string" }, reason: { type: "string" },
                             verdict: { type: "string", enum: VERDICTS }, replacement: { type: "string" })
    AI_SCHEMA = Suggest::ROW.call(lines: { type: "array", items: LINE }).freeze
    AI_DID_NOT_RUN = "No protected attribute is named. The AI test did not run; a person confirms the line is task-related and testable."
    NAMED = "The requirement names a protected attribute or asks for something the work does not need. Reword it to what the work needs."

    module_function

    # job: the vacancy whose requirements are tested. Returns the lines, one per requirement, in
    # rubric order (must-have, should-have, nice-to-have).
    def call(job)
      requirements = job.requirements.reorder(:tier, :position, :id).to_a
      rule = rule_lines(requirements)
      ai = ai_lines(requirements)
      requirements.map do |r|
        key = "R#{r.id}"
        line = rule[key] || ai[key] || { "id" => key, "text" => r.text, "verdict" => "keep", "reason" => AI_DID_NOT_RUN, "replacement" => "", "source" => "rule" }
        # A rule hit keeps its verdict and reason; it borrows the AI's neutral wording when there is one.
        line = line.merge("replacement" => ai.dig(key, "replacement").to_s) if rule[key] && ai[key] && line["replacement"].empty?
        line
      end
    end

    def open?(lines) = Array(lines).any? { |l| l["verdict"] != "keep" }

    # The rule table of the ad scan, applied to each requirement's text and CV-evidence line.
    def rule_lines(requirements)
      requirements.each_with_object({}) do |r, acc|
        text = "#{r.text} #{r.cv_evidence}"
        reason = AdCheck::RULES.find { |pattern, _| text.match?(pattern) }&.last
        next unless reason

        acc["R#{r.id}"] = { "id" => "R#{r.id}", "text" => r.text, "verdict" => "replace", "reason" => "#{reason} #{NAMED}",
                            "replacement" => "", "source" => "rule" }
      end
    end

    # One AI call for the whole brief. An id the brief does not have, a verdict outside the enum,
    # or a "replace" without wording is dropped (the line then falls back to the rule pass).
    def ai_lines(requirements)
      return {} unless Screening::Config.enabled? && requirements.any?

      content = JSON.pretty_generate(requirements.map { |r| { "id" => "R#{r.id}", "tier" => r.tier, "requirement" => r.text, "cv_evidence" => r.cv_evidence } })
      reply = Screening::Config.client(:discrimination_check, job: requirements.first.job).generate(system: AI_SYSTEM, schema: AI_SCHEMA, content:)
      by_key = requirements.index_by { |r| "R#{r.id}" }
      Array(JSON.parse(reply.text)["lines"]).grep(Hash).each_with_object({}) do |l, acc|
        r = by_key[l["id"].to_s]
        verdict = l["verdict"].to_s
        replacement = l["replacement"].to_s.strip
        next if r.nil? || !VERDICTS.include?(verdict) || (verdict == "replace" && replacement.empty?)

        acc["R#{r.id}"] = { "id" => "R#{r.id}", "text" => r.text, "verdict" => verdict, "reason" => l["reason"].to_s.strip,
                            "replacement" => (verdict == "replace" ? replacement : ""), "source" => "ai" }
      end
    rescue Screening::Errors::Base, JSON::ParserError, NoMethodError, TypeError
      {} # the rule lines still stand; the screen says the AI test did not run
    end
  end
end
