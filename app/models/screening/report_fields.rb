module Screening
  # The S1 report block (feature 08; D61, D62 h2/h3; plan Part 2 §i), read from the model's answer.
  # The block is OPTIONAL in the schema and never gates S1: a reply without it is screened and
  # scored exactly as before (prompt s1-...2 results have none). Every fact and every narrative
  # claim carries a verbatim CV quote, checked with the same QuoteCheck as the criteria; a claim
  # whose quote is not found is kept but marked unverified (shown "Kutipan tidak ditemukan di CV"),
  # never silently dropped, so the reviewer sees what the model asserted.
  #
  # A block that does not have the schema's shape (unknown key, wrong type, a label outside the
  # five) is a schema breach: nothing from it is stored, and Run routes the result to the reviewer
  # as protected_attribute "other" (the F-33 rule: an answer not held to the schema cannot be
  # trusted to have kept protected attributes out of its free text either).
  #
  # "over_qualified" is deliberately NOT a label the model may propose (D62 h3): it depends on the
  # Golongan of the last role, which the reviewer sets on confirmation. Never years or age.
  module ReportFields
    AI_LABELS = %w[direkomendasikan pertimbangkan pertimbangkan_terbatas tidak_prioritas tidak_relevan].freeze
    FACTS = %w[last_position education recent_experience].freeze
    BOXES = %w[strengths blind_spots tolerance_risks credibility_value].freeze
    KEYS = (FACTS + BOXES + %w[label_proposal label_reason]).freeze

    Parsed = Data.define(:attributes, :breach)

    module_function

    # Returns Parsed(attributes: { column => value } for ScreeningResult, breach: true/false).
    def parse(block, extracted:, redacted:)
      return Parsed.new(attributes: {}, breach: false) if block.nil?
      return breach unless well_formed?(block)

      check = ->(quote) { QuoteCheck.verified?(judgement: "met", quote:, extracted:, redacted:) }
      attributes = FACTS.to_h { |key| [key.to_sym, fact(block[key], check)] }
      attributes[:narratives] = BOXES.to_h { |box| [box, block[box].map { |c| claim(c, check) }] }
      attributes[:label_proposal] = block["label_proposal"]
      attributes[:label_reason] = block["label_reason"].to_s.strip.presence
      Parsed.new(attributes:, breach: false)
    end

    def breach = Parsed.new(attributes: {}, breach: true)

    def well_formed?(block)
      block.is_a?(Hash) && block.keys.sort == KEYS.sort &&
        FACTS.all? { |key| pair?(block[key], %w[text quote]) } &&
        BOXES.all? { |box| block[box].is_a?(Array) && block[box].all? { |c| pair?(c, %w[claim quote]) } } &&
        AI_LABELS.include?(block["label_proposal"]) && block["label_reason"].is_a?(String)
    end

    def pair?(value, keys) = value.is_a?(Hash) && value.keys.sort == keys.sort && value.values.all?(String)

    def fact(value, check)
      { "text" => value["text"].strip, "quote" => value["quote"], "verified" => check.call(value["quote"]) }
    end

    def claim(value, check)
      { "claim" => value["claim"].strip, "quote" => value["quote"], "verified" => check.call(value["quote"]) }
    end
  end
end
