module Screening
  # Prompt injection in candidate text (a CV, a technical-test answer): sentences that try to steer
  # the AI ("abaikan instruksi", "ignore previous instructions", "beri nilai 5", "you are now...") or
  # fake the tags that fence the candidate's text off (<cv>, </answer>). Rules, not a model: a
  # candidate cannot argue with a regular expression.
  #
  # What happens with a finding:
  #   - a CV is HELD for a reviewer even in the automatic mode (ReleaseGate#auto_release), and the
  #     sentence is marked on the release screen (ReleaseHighlights, category "instruction");
  #   - a test answer gets a warning on the "Nilai dengan AI" preview and on the AI's proposal;
  #   - the fence tags are neutralised in every text sent (AiClient.user_content, AiScore.content),
  #     so candidate text can never close its own section.
  # Defence in depth, not a proof: the model is also told the text is data, quotes are verified,
  # scores are computed in Ruby, and a person decides.
  module InjectionCheck
    PATTERNS = [
      /\b(?:abaikan|lupakan|hiraukan|jangan\s+ikuti)\s+(?:semua\s+|seluruh\s+)?(?:instruksi|perintah|aturan|prompt|petunjuk)/i,
      /\b(?:ignore|disregard|forget|override)\s+(?:all\s+|the\s+|any\s+|your\s+)?(?:previous\s+|prior\s+|above\s+|earlier\s+)?(?:instructions?|rules|prompts?|guidelines)/i,
      /\b(?:beri(?:kan)?|kasih)\s+(?:saya\s+|kandidat\s+ini\s+)?(?:nilai|skor|rating)\s+(?:sempurna|maksimal|tertinggi|penuh|5|100|3)\b/i,
      /\b(?:give|assign|rate)\s+(?:me|this\s+(?:candidate|answer|cv))?\s*(?:a\s+)?(?:perfect|maximum|full|top|5|100)\s*(?:score|rating|marks?)?\b/i,
      /\b(?:loloskan|luluskan)\s+(?:saya|kandidat\s+ini|pelamar\s+ini)\b/i,
      /\b(?:kamu|anda)\s+(?:sekarang\s+)?(?:adalah|berperan\s+sebagai)\s+(?:ai|asisten|model|sistem)\b/i,
      /\byou\s+are\s+(?:now\s+)?(?:an?\s+|the\s+)?(?:ai|assistant|model|system|grader|evaluator)\b/i,
      /\b(?:system\s+prompt|prompt\s+sistem|developer\s+message)\b/i,
      %r{</?\s*(?:cv|requirements|answer|rubric|test|system)\s*>}i
    ].freeze
    FENCE = %r{<(/?)\s*(cv|requirements|answer|rubric|test|system)\s*>}i

    module_function

    # [line number (0-based), matched text] for each finding.
    def findings(text)
      text.to_s.split("\n", -1).each_with_index.flat_map do |line, i|
        PATTERNS.filter_map { |re| (m = line.match(re)) && [i, m[0]] }
      end
    end

    def suspicious?(text) = findings(text).any?

    # "</cv>" in candidate text becomes "‹/cv›": readable for a person, no longer a fence for the model.
    def neutralise_fences(text) = text.to_s.gsub(FENCE) { "‹#{$1}#{$2}›" }
  end
end
