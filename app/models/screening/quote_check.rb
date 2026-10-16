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
  module QuoteCheck
    module_function

    def normalise(text) = text.to_s.gsub(/[[:space:]]+/, " ").strip

    def verified?(judgement:, quote:, extracted:, redacted:)
      q = normalise(quote)
      return !positive?(judgement) if evidence_free?(q)

      haystack = q.include?(Redactor::MARK) ? redacted : extracted
      normalise(haystack).include?(q)
    end

    def evidence_free?(quote) = quote.gsub(Redactor::MARK, "").gsub(/[[:space:][:punct:]]/, "").empty?

    def positive?(judgement) = %w[met 1 2 3].include?(judgement.to_s)
  end
end
