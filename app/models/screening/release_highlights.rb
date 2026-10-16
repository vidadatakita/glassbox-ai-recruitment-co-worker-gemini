module Screening
  # What the release screen ("Pemeriksaan sebelum AI", D51 B) marks inside the text a reviewer is
  # about to release. Two kinds, never confused on screen:
  #
  #   blocking  the residual-check SHAPES (Screening::ResidualCheck): ID number, phone, date of
  #             birth, email, personal-data label with a value, a word of the candidate's name.
  #             While any remains, "Kirim ke AI" is refused (fail closed, ADR 0004); the reviewer
  #             cuts the line or declines.
  #   hint      protected WORDS the redactor deliberately leaves inside evidence sections (F-27:
  #             "Kasir di Toko Gadis Mart" is evidence), plus family and place-of-worship words that
  #             no list covers. Engine run 5 showed 8 of 9 planted protected sentences reaching the
  #             request body through exactly this gap. A hint never blocks; it points the reviewer's
  #             eye. The word lists of the redactor are frozen (ADR 0004); these are display-only and
  #             change nothing that is sent.
  #
  # Returns spans per line, so the screen marks them INSIDE the text block and the summary outside
  # it lists only category names and line numbers, never a value.
  module ReleaseHighlights
    Span = Data.define(:line, :start, :length, :category, :blocking)

    BLOCKING_LABELS = ResidualCheck::CATEGORIES
    HINT_LABELS = {
      "religion" => "religion", "marital" => "marital status", "gender" => "gender",
      "ethnicity" => "ethnicity", "family" => "family", "worship" => "place or activity of worship",
      "instruction" => "a sentence trying to steer the AI"
    }.freeze

    HINTS = {
      "religion" => Redactor::RELIGION, "marital" => Redactor::MARITAL, "gender" => Redactor::GENDER,
      "ethnicity" => Redactor::ETHNIC,
      "family" => /\b(?:suami|istri|isteri|anak(?:\s+(?:saya|pertama|kedua|ketiga))?|ibu\s+(?:dua|tiga|satu|\d)|ayah|bapak\s+(?:dua|tiga|\d)|hamil|mertua|cucu|keluarga\s+saya)\b/i,
      "worship" => /\b(?:masjid|mesjid|musholla|mushola|gereja|pura|vihara|klenteng|pesantren|mengaji|pengajian|rohis|rohani|ibadah|jemaat|majelis\s+taklim)\b/i
    }.freeze

    module_function

    # lines: the payload's lines; range: the CV line numbers (only they are scanned; the
    # requirements part is the job's own text). names: the candidate's name(s).
    def spans(lines, range, names: [], today: Date.current)
      range.flat_map do |i|
        line = lines[i].to_s
        blocking_spans(line, i, names, today) + hint_spans(line, i)
      end
    end

    def blocking_spans(line, index, names, today)
      out = []
      add = ->(re, cat) { line.to_enum(:scan, re).each { out << Span.new(index, $~.begin(0), $~[0].length, cat, true) } }
      add.call(ResidualCheck::ID_NUMBER, "id_number")
      line.to_enum(:scan, ResidualCheck::PHONE).each do
        out << Span.new(index, $~.begin(0), $~[0].length, "phone", true) if $~[0].scan(/\d/).size >= 10
      end
      add.call(ResidualCheck::EMAIL, "email")
      add.call(ResidualCheck::LABELS, "label")
      if ResidualCheck.birth_date_line?(line.strip, today)
        (ResidualCheck::FULL_DATES + [ResidualCheck::MONTH_YEAR]).each { |re| add.call(re, "birth_date") }
      end
      names.compact.flat_map { |n| n.to_s.split(/\s+/) }.select { |w| w.length >= 3 }.uniq.each do |w|
        add.call(/(?<![[:alpha:]])#{Regexp.escape(w)}(?![[:alpha:]])/i, "name")
      end
      out
    end

    def hint_spans(line, index)
      words = HINTS.flat_map do |category, re|
        line.to_enum(:scan, re).map { Span.new(index, $~.begin(0), $~[0].length, category, false) }
      end
      # Prompt injection (Screening::InjectionCheck): why an automatic-mode CV was held.
      words + InjectionCheck::PATTERNS.flat_map do |re|
        line.to_enum(:scan, re).map { Span.new(index, $~.begin(0), $~[0].length, "instruction", false) }
      end
    end

    def label(category) = BLOCKING_LABELS[category] || HINT_LABELS.fetch(category, category)

    # Non-overlapping spans for one line, blocking first, then by position (an overlapping later
    # span is dropped so the text is rendered exactly once).
    def merged(line_spans)
      taken = []
      line_spans.sort_by { |s| [s.blocking ? 0 : 1, s.start] }.each do |s|
        next if taken.any? { |t| s.start < t.start + t.length && t.start < s.start + s.length }

        taken << s
      end
      taken.sort_by(&:start)
    end
  end
end
