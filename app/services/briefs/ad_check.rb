# frozen_string_literal: true

module Briefs
  # AI Builder Cup step 02: is the job ad free of requirements that exclude people for who they are
  # rather than what the work needs? Two checks on the text HR saves:
  #   - rules (RULES): words that name a protected attribute (age, gender, appearance, marital
  #     status, religion, ethnicity, body);
  #   - the AI (when configured): the sentences the rules miss ("fresh graduate, maks. 25", "cocok
  #     untuk ibu rumah tangga"), each with a reason. If the AI is off or fails, the rules stand.
  # A word can be innocent ("terbuka untuk pria maupun wanita"), so no flag blocks for good. Any flag
  # makes HR tick "I have checked the flags above" before approving (JobsController#approve_ad),
  # the same pattern as the CV release screen. A RULE flag names a protected attribute outright, so
  # (16 Oct test: "Female, max 28, attractive, unmarried" was approved and shown publicly) it also
  # needs a written reason from HR, recorded with the approval, like a flagged requirement kept in
  # the brief's discrimination test (Briefs::RequirementCheck); a live ad's save with one needs the
  # reason too (Briefs::SaveAd). AI flags (proxies, a judgement call) still need the tick only.
  # Each flag: { "quote" (copied from the text), "reason", "source" => "rule" | "ai" }; a rule flag
  # also carries "categories", every attribute the line names.
  module AdCheck
    # One row per protected attribute, [category, pattern, reason], Indonesian AND English patterns
    # (the English ones added 16 Oct 2026 for the English demo ad; the Indonesian rows are
    # unchanged). Chosen to name the attribute itself, not every proxy: "single" alone is not here
    # ("Single Page Application"), "native" alone is not here; the AI pass below reads proxies in
    # context.
    RULE_TABLE = [
      ["age", /\b(usia|umur|berumur)\b|\bmaks(?:imal|\.)?\s*\d{2}\s*(?:tahun|thn)\b|\b(?:maximum|max\.?|under|below)\s+(?:age\s+)?\d{2}\b|\b\d{2}\s*(?:years?\s+old|y\.?o\.?)\b|\bage\s+(?:limit|range|between|under|below|max)\b|\byoung\b/i,
       "An age limit may not be a requirement unless the law requires it."],
      ["gender", /\b(pria|wanita|laki-laki|laki laki|perempuan|jenis kelamin|gender|male|female|men\s+only|women\s+only|man|woman)\b/i,
       "Gender may not be a requirement when anyone can do the work."],
      ["appearance", /\b(berpenampilan|penampilan menarik|good looking|cantik|tampan|attractive|presentable|pleasant\s+appearance|well[- ]groomed)\b/i,
       "Physical appearance is not a work ability."],
      ["marital status", /\b(belum menikah|lajang|status (?:pernikahan|perkawinan)|tidak hamil|unmarried|not\s+married|marital\s+status|not\s+pregnant|no\s+children|childless)\b/i,
       "Marital status or pregnancy may not be a requirement."],
      ["body size", /\b(tinggi badan|berat badan|postur|body\s+(?:size|shape|weight|height)|(?:minimum|min\.?|maximum|max\.?)\s+(?:height|weight)|height\s+(?:of\s+)?(?:at\s+least|minimum|min\.?|above|over)|\d{3}\s*cm)\b/i,
       "Body size may only be asked for when the work truly needs it; write the reason."],
      ["religion", /\b(agama|muslim|muslimah|kristen|katolik|hindu|buddha|non[- ]?muslim|religion|christian|catholic|protestant|buddhist|islamic|hijab)\b/i,
       "Religion may not be a requirement."],
      ["ethnicity", /\b(suku bangsa|suku tertentu|etnis|ras|keturunan|pribumi|ethnicity|ethnic|race(?!\s+condition)|descent|local\s+people\s+only|locals\s+only)\b/i,
       "Ethnicity or descent may not be a requirement."]
    ].freeze
    # [pattern, reason] per row: the shape Briefs::DiscriminationCheck reads.
    RULES = RULE_TABLE.map { |_category, pattern, reason| [pattern, reason] }.freeze

    # 16 Oct accuracy pass: the screening standard's full §8 list, what is fine said explicitly (so
    # inclusive sentences are not flagged), and quote rules matching the check below (a quote that
    # is not a substring of the ad is dropped).
    AI_SYSTEM = <<~PROMPT.freeze
      You review a job ad of an Indonesian employer for requirements that exclude people for who
      they are rather than what the work needs: age; gender; appearance, height, weight or body
      size; marital status, pregnancy or children; religion; ethnicity, descent or region of origin;
      political views or union membership; disability or health not needed for the work; family
      data. Flag their stand-ins too: "fresh graduate" (required or excluded), a maximum number of
      years of experience, a graduation-year limit, "young", "energetic", "native speaker",
      "suitable for housewives", "presentable", a photo, a family card or a bank account asked for
      at application, the last salary as the basis of the offer.
      Fine and never flagged: skills, experience (a minimum), education, licences, certificates,
      languages at a stated level, location, working hours, shifts, travel, and sentences that
      welcome everyone ("open to all genders", "people with disabilities are encouraged to apply").
      Return flags: each with quote (the shortest exact words that carry the problem, copied
      character for character from the ad, never joined from two places) and reason (one sentence
      in English naming the attribute or stand-in). Return an empty list when there is nothing to
      flag.
    PROMPT
    AI_SCHEMA = Suggest::ROW.call(flags: { type: "array", items: Suggest::ROW.call(quote: { type: "string" }, reason: { type: "string" }) }).freeze

    module_function

    def call(text)
      flags = rule_flags(text)
      flags + ai_flags(text, already: flags.map { |f| f["quote"] })
    end

    def flagged?(flags) = Array(flags).any?

    # A flag from the rule table: the ad names a protected attribute, and approving it needs a
    # written reason.
    def rule_hit?(flags) = Array(flags).any? { |f| f["source"] == "rule" }

    # The attributes the rule flags name, each once, in rule-table order ("age, gender").
    def rule_categories(flags)
      named = Array(flags).select { |f| f["source"] == "rule" }.flat_map { |f| Array(f["categories"]) }
      RULE_TABLE.map(&:first) & named
    end

    # One sentence for the screens: "The job ad names a protected attribute (age, gender)." (Flags
    # stored before 16 Oct carry no categories; the sentence then names none.)
    def rule_summary(flags)
      categories = rule_categories(flags)
      "The job ad names a protected attribute#{" (#{categories.join(', ')})" if categories.any?}."
    end

    # One flag per line that trips a rule (the whole line is the quote, trimmed), with EVERY row
    # the line trips: its categories and their reasons, in rule-table order.
    def rule_flags(text)
      text.to_s.lines.filter_map do |line|
        rows = RULE_TABLE.select { |_category, pattern, _reason| line.match?(pattern) }
        next if rows.empty?

        { "quote" => line.strip.truncate(160), "reason" => rows.map(&:last).join(" "), "source" => "rule",
          "categories" => rows.map(&:first) }
      end
    end

    # A quote must be words that are really in the ad (else it is dropped); one already flagged by a
    # rule is not repeated.
    def ai_flags(text, already:)
      return [] unless Screening::Config.enabled? && text.present?

      reply = Screening::Config.client(:ad_scan).generate(system: AI_SYSTEM, schema: AI_SCHEMA, content: text)
      Array(JSON.parse(reply.text)["flags"]).grep(Hash).filter_map do |f|
        quote = f["quote"].to_s.strip
        next if quote.empty? || !text.include?(quote) || already.any? { |q| q.include?(quote) }

        { "quote" => quote.truncate(160), "reason" => f["reason"].to_s.strip, "source" => "ai" }
      end
    rescue Screening::Errors::Base, JSON::ParserError, NoMethodError, TypeError
      [] # the rule check still stands; the screen says the AI check did not run
    end
  end
end
