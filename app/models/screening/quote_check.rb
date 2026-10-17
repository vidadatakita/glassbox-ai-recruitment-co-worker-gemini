module Screening
  # Blueprint §4.1 step 6: a quote that is not found in the extracted CV text marks that criterion
  # `unverified`, and the application goes to the reviewer. Matching normalises WHITESPACE ONLY
  # (runs of spaces, tabs and line breaks become one space; ends trimmed). Case, punctuation and
  # spelling must match exactly: a paraphrase is not a quote.
  #
  # One deliberate extension: the model only ever sees the REDACTED text, so a quote that spans a
  # redaction marker cannot exist in the extracted text. Such a quote is checked, exactly the same
  # way, against the redacted text the model was given. It still has to be verbatim.
  #
  # Which judgements need a quote: a positive one (wajib "met", rating 1-3) must carry a non-empty
  # quote that is found. A negative one ("not_met", 0) may have an empty quote; if it carries a
  # quote, that quote must be found too (an invented quote is a defect whatever it supports).
  #
  # A quote that is ONLY redaction markers (plus spaces or punctuation), such as "[REDACTED]", holds
  # no evidence: it counts as an empty quote, so a positive judgement backed by it is unverified
  # and goes to the reviewer (test engine run 1, F-03). Otherwise a model could "quote" the marker
  # and pass every wajib unchecked.
  #
  # Prompt s1-2026-10-16.4: a criterion carries one to three passages ("quotes"), so a requirement
  # that asks for two things ("journals and bank reconciliations") can be backed from two lines.
  # EVERY passage is checked on its own; the criterion is verified only when all of them are found
  # and, for a positive judgement, at least one carries evidence. The passages are stored in the
  # criterion's one "quote" field, joined with SEPARATOR, so the erasure (every "quote" set to
  # null), the exports and every reader of a stored judgement work unchanged. Rejected: a new
  # "quotes" key in the stored judgements, which the erasure trigger would not null.
  module QuoteCheck
    # An ellipsis between excerpts is how a reader expects separate passages to be shown.
    SEPARATOR = " … ".freeze

    module_function

    def normalise(text) = text.to_s.gsub(/[[:space:]]+/, " ").strip

    # One passage: a fact or claim of the report block, or a criterion in the one-quote shape.
    def verified?(judgement:, quote:, extracted:, redacted:) = all_verified?(judgement:, quotes: [quote], extracted:, redacted:)

    def all_verified?(judgement:, quotes:, extracted:, redacted:)
      evidence = Array(quotes).map { |q| normalise(q) }.reject { |q| evidence_free?(q) }
      return !positive?(judgement) if evidence.empty?

      evidence.all? { |q| normalise(q.include?(Redactor::MARK) ? redacted : extracted).include?(q) }
    end

    # The passages of one criterion entry of an AI answer: "quotes" (a list, prompt .4 on) or
    # "quote" (one string, the shape up to prompt .3; still read, so an answer or a test double in
    # that shape is checked the same way). Empty entries and repeats carry nothing and are dropped.
    def passages_of(entry)
      list = entry["quotes"].is_a?(Array) ? entry["quotes"] : [entry["quote"]]
      list.map { |q| q.to_s.strip }.reject(&:empty?).uniq
    end

    # The stored fields of one criterion entry: { "quote" => the passages joined, "verified" }.
    def check(entry, judgement:, extracted:, redacted:)
      passages = passages_of(entry)
      { "quote" => passages.join(SEPARATOR), "verified" => all_verified?(judgement:, quotes: passages, extracted:, redacted:) }
    end

    # One quote string that may hold several excerpts joined or cut short with an ellipsis ("…" or
    # "..."), as the model writes them when it shortens a long passage. Each excerpt must be found
    # verbatim on its own, and at least one must carry evidence; the ellipsis itself is never matched.
    # Used for competency-test written answers (ApplicationDrafts::AiRate), whose prompt asks for one
    # quote string: before this, a correct but shortened quote failed the plain substring match and
    # sent the answer to a person (17 Oct 2026 sample run: 2 of the 3 strongest applicants).
    # An answer that itself contains "..." still verifies: its quote splits at the same places.
    ELLIPSIS = /…|\.{3,}/

    def excerpts_found?(quote, text)
      excerpts = quote.to_s.split(ELLIPSIS).map { |q| normalise(q) }.reject { |q| evidence_free?(q) }
      haystack = normalise(text)
      excerpts.any? && excerpts.all? { |q| haystack.include?(q) }
    end

    # A stored quote back as its passages, for display (nil after erasure: none).
    def passages(stored) = stored.to_s.split(SEPARATOR).map(&:strip).reject(&:empty?)

    def evidence_free?(quote) = quote.gsub(Redactor::MARK, "").gsub(/[[:space:][:punct:]]/, "").empty?

    def positive?(judgement) = %w[met 1 2 3].include?(judgement.to_s)
  end
end
