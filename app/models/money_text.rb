# Money in free text (D62 h5: the expected salary is NEVER sent to the AI; spec section 4: nor the
# current salary). ONE module, used for every text of every D63 request (gate, S3, S4, S5 advice and the
# salary position; engine 11 F-02, F-12, F-13, F-17).
#
# Three steps, because four redaction rounds in feature 06 showed that a growing denylist keeps leaking:
#   0. KEEP   a number IMMEDIATELY followed by a physical or count unit is not money and is neither
#             stripped nor refused: "beban 500 kg", "100 SKU per jam", "stok 1.200 karton", "gudang
#             2.000 m2", "kecepatan 120 wpm"; also "ISO 9001", "nilai 85 dari 100" and a score "85/100".
#             A number followed by a money marker is never a unit (the unit list holds no money word;
#             "7.5M" with a capital M is money, "5 m" with a small m is metres).
#   1. STRIP  every money shape the pattern knows becomes the redaction marker (Screening::Redactor::MARK, "[REDACTED]"): a currency code or symbol with a
#             number (Rp, IDR, USD, US$, S$, SGD, EUR, MYR, AUD, JPY, $, euro, pound, yen); a number (with
#             a fraction such as "7 1/2" or "7½") followed by rupiah, perak, juta(an), jt, ribu(an), rb,
#             k, M, mil, mio, million, billion, bn, thousand, miliar / milyar; the Indonesian number words
#             (se-, satu .. sembilan with puluh, belas, ratus, ribu, juta, miliar, triliun; setengah,
#             seperempat); English number words ending in hundred / thousand / million / billion; the
#             bare words rupiah, perak, jt, rb, million, mio, bn; digits in groups of three; any run of
#             five or more digits.
#   2. SHAPE  after stripping, a request is REFUSED ("Perlu cek manual") when it still holds a money
#             shape, a run of three or more digits that is not a kept unit number or a known non-money
#             token (a year 1900-2099, a percentage, a scale "1-5", the ids [N123] and R123), or any digit
#             next to the marker ("7 juta 500" leaves "[REDACTED] 500").
# Remaining false positives (measured, feature 11 part 8): a number followed by a word that is not in
# the unit list ("500 meter persegi" is kept only as "500 m2"; "3 kali" or "120 kata per menit" stop the
# request), and a three-digit code that is not ISO ("SAP 300", "kelas 400").
module MoneyText
  MARK = Screening::Redactor::MARK
  NUMBER = /\d+(?:[.,]\d+)*(?:\s+\d\/\d|½|¼|¾)?/
  EN_NUMBER = /(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|and|a|half)/
  MONEY_WORD = /rupiah|perak|jutaan|juta|jt|ribuan|ribu|rb|miliar|milyar|triliun|million|billion|thousand|mil|mio|bn|k/

  WORDS = /\b(?:se|satu|dua|tiga|empat|lima|enam|tujuh|delapan|sembilan)?(?:puluh|belas|ratus|ribu|ribuan|juta|jutaan|miliar|milyar|triliun)\b|\b(?:sepuluh|sebelas|seratus|seribu|sejuta|semiliar|setengah|seperempat|rupiah|perak|jt|rb|million|billion|thousand|mio|bn)\b/i
  EN_WORDS = /\b(?:#{EN_NUMBER.source}[\s-]+)*(?:hundred|thousand|million|billion)\b/i
  CURRENCY = /(?:\b(?:rp|idr|usd|sgd|eur|myr|aud|jpy)|\b(?:us|s)\$|[$€£¥])\.?\s*#{NUMBER.source}(?:,-)?/i
  SUFFIXED = /#{NUMBER.source}\s*-?\s*(?:(?i:#{MONEY_WORD.source})\b|M\b)/
  GROUPED = /\d{1,3}(?:[.,]\d{3})+(?:,\d+)?/
  LONG = /\d{5,}/
  CODES = /\b(?:rp|idr|usd|sgd|eur|myr|aud|jpy)\b|[$€£¥]/i
  PATTERN = Regexp.union(CURRENCY, SUFFIXED, GROUPED, LONG, EN_WORDS, WORDS, CODES)

  UNITS = /(?:(?i:kg|g|gr|gram|ton|t|km|cm|mm|liter|litre|l|ml|wpm|rpm|jam|menit|detik|hari|minggu|bulan|tahun|orang|karyawan|staf|staff|palet|pallet|karton|dus|box|unit|pcs|sku|item|rak|lantai|shift|x)\b|m(?:2|3)?\b|m[²³]|°C|%)/
  KEEP = Regexp.union(
    /(?<![\d.,])\d+(?:[.,]\d+)*\s?#{UNITS.source}(?!\s*-?\s*(?i:#{MONEY_WORD.source})\b)/,
    /\bISO\s?\d+(?::\d{4})?\b/i,
    /\bnilai\s+\d+(?:[.,]\d+)?\s+dari\s+\d+\b/i,
    /(?<![\d.,])\b\d{1,3}\/\d{1,3}\b(?!\s*-?\s*(?:(?i:#{MONEY_WORD.source})\b|M\b))/
  )
  ALLOWED = Regexp.union(/\b(?:19|20)\d{2}\b/, /\d+(?:[.,]\d+)?\s*%/, /\b\d\s*[-–]\s*\d\b/, /\[N\d+\]/, /\bR\d+\b/)
  SUSPICIOUS = /\d{3,}/
  # Built from MARK, never a literal: when the marker was renamed from [DIHAPUS] to [REDACTED]
  # (A3, 2026-10-16) a literal here silently stopped suspicious? from ever matching.
  ADJACENT = /\d\s*\(?#{Regexp.escape(MARK)}|#{Regexp.escape(MARK)}\)?\s*\d/
  PLACEHOLDER = 0xF0000 # Supplementary Private Use Area-A: never in typed text, holds no digit.

  module_function

  def strip(text) = keeping(text) { |masked| masked.gsub(PATTERN, MARK) }

  CURRENCY_BEFORE = /(?:\b(?:rp|idr|usd|sgd|eur|myr|aud|jpy)\.?|[$€£¥])\s*\z/i

  # A kept span never carries a figure of a million or more ("Gaji 7.000.000 bulan ini" is money even
  # though "bulan" is a unit word), and never follows a currency code ("Rp 500 kg" is money).
  def keep?(match) = match[0].scan(/\d/).size < 7 && !match.pre_match.match?(CURRENCY_BEFORE)

  # True when the text still holds a money shape, an unexplained run of three or more digits, or a digit
  # next to a stripped figure.
  def suspicious?(text)
    rest = text.to_s.gsub(KEEP) { |span| keep?(Regexp.last_match) ? " " : span }.gsub(ALLOWED, " ")
    rest.match?(PATTERN) || rest.match?(SUSPICIOUS) || rest.match?(ADJACENT)
  end

  # Replaces each kept span by one private-use character, runs the block, puts the spans back.
  def keeping(text)
    kept = []
    masked = text.to_s.gsub(KEEP) { |span| keep?(Regexp.last_match) ? [PLACEHOLDER + (kept << span).size - 1].pack("U") : span }
    yield(masked).gsub(/[\u{F0000}-\u{FFFFD}]/) { |c| kept.fetch(c.ord - PLACEHOLDER) }
  end
end
