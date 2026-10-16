module Screening
  # Structural layer 2 (ADR 0004): FAIL CLOSED. After redaction, the text about to be sent is
  # scanned for shapes that personal data takes whatever its label: a 15-16 digit number (NIK,
  # NPWP), a phone number, a date of birth, an email address, a personal-data label, or the
  # candidate's own name. If any remains, NOTHING is sent. Since D51 (feature 09) the CV goes to
  # the reviewer's release screen ("Menunggu pemeriksaan") with the findings marked, and that
  # version cannot be released (Screening::ReleaseGate, database trigger on ai_release_actions):
  # the reviewer cuts the line ("Hapus bagian") or declines. Before D51 it went to "Perlu cek
  # manual" (screening_failed, personal_data); rows in that state still accept a pasted text.
  #
  # Why: two test-engine rounds each found new header forms the redactor's patterns missed (F-01,
  # F-02, F-09..F-11). Patterns decide what to REMOVE and can always miss a form; this check decides
  # whether it is SAFE TO SEND and errs towards a human. It reports the category only, never the
  # value (the detail is shown on screen and stored).
  #
  # Cost of a false alarm: a manual look at one CV, no API call. A date of birth is any full date
  # (day, month, year) with a year from 1950 to 15 years before today, so an old certificate or a
  # first job dated to the day before that also triggers it. Accepted: fail closed.
  module ResidualCheck
    MONTHS = "jan(?:uari|uary)?|feb(?:ruari|ruary)?|mar(?:et|ch)?|apr(?:il)?|mei|may|jun(?:i|e)?|jul(?:i|y)?|ag(?:u)?s(?:tus)?|aug(?:ust)?|sep(?:t(?:ember)?)?|okt(?:ober)?|oct(?:ober)?|nov(?:ember)?|des(?:ember)?|dec(?:ember)?".freeze
    FULL_DATES = [
      /(?<!\d)(\d{1,2})[\-\/.](\d{1,2})[\-\/.](\d{4}|\d{2})(?![\d\-\/.]?\d)/,
      /(?<!\d)(\d{4})[\-\/.](\d{1,2})[\-\/.](\d{1,2})(?!\d)/,
      /(?<!\d)(\d{1,2})\s+(?:#{MONTHS})\.?\s+'?(\d{4}|\d{2})(?!\d)/i
    ].freeze
    # Month and year only ("Maret 1995"): a birth date only on a "Place, Month Year" line.
    MONTH_YEAR = /(?:#{MONTHS})\.?\s+'?(\d{4}|\d{2})(?!\d)/i
    # F-24: a date on a line about work (a period, a certificate, an employer or a role) is not a date
    # of birth. A date next to lahir / born / TTL, or alone after a place name ("Bandung, 12-03-1995"),
    # is. Anything else in the birth-year range stays a finding (fail closed).
    BIRTH_CONTEXT = /\b(?:lahir|kelahiran|born|ttl|dob|birth|umur|usia|age)\b/i
    # F-25: work context needs a real work marker on the line (employer, role, certificate) or a date
    # RANGE (two dates or month-years). "sekarang", "(kontrak)" or a dash alone are not enough: a
    # date of birth can be dressed in them.
    WORK_MARKER = %r{\b(?:pt|cv|tbk|ud|perusahaan|company|corp|inc|ltd|sertifikat|sertifikasi|certificate|certified|terbit|issued|berlaku|valid|ijazah|lulus|graduated|staf|staff|supervisor|admin|operator|manager|manajer|koordinator|kepala|kasir|sales|teknisi|technician|driver|helper|leader|asisten|assistant|officer|clerk|engineer|analis|analyst|magang|intern|internship|guru|perawat)\b}i
    # "Bandung, 12-03-1995", "Bandung, 12 Mar '95", "Bandung, Maret 1995": a place, a comma, and
    # NOTHING but a date. ("Operator Forklift SIO, terbit 12 Maret 2010" is not one.)
    PLACE_DATE_LINE = /\A[\s\-•*]*[[:upper:]][[:alpha:]]+(?:\s+[[:upper:]][[:alpha:]]+){0,2}\s*,\s*(?:\d{1,2}\s*[\-\/.\s]\s*)?(?:\d{1,2}|(?:#{MONTHS}))\.?\s*[\-\/.\s]\s*'?\d{2,4}(?!\d)/i
    ID_NUMBER = /(?<!\d)(?:\d[\s.\-]?){14,15}\d(?!\d)/
    PHONE = /(?<![\d\w])(?:\+\s?\(?62\)?|\(?62\)?|\(?0)[\d\s.\-()]{7,}\d/
    EMAIL = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i
    # A personal-data label still followed by a value (a label whose value was replaced by the
    # marker is harmless and is not a finding).
    LABELS = /\b(?:agama|religion|kelahiran|(?:tgl|tanggal)\.?\s*lahir|tempat\s+lahir|date\s+of\s+birth|jenis\s+kelamin|status\s+(?:pernikahan|perkawinan)|marital\s+status|npwp|nik|no\.?\s*ktp|nomor\s+ktp)\b(?>\s*[:\-]?\s*)(?!\[REDACTED\]|\z)\S/i

    CATEGORIES = {
      "id_number" => "identity number", "phone" => "phone number", "birth_date" => "date of birth",
      "email" => "email", "label" => "personal-data label", "name" => "applicant name"
    }.freeze

    module_function

    # Returns the category keys found (empty = safe to send).
    def findings(text, names: [], today: Date.current)
      found = []
      found << "id_number" if text.match?(ID_NUMBER)
      found << "phone" if text.scan(PHONE).any? { |m| m.scan(/\d/).size >= 10 }
      found << "birth_date" if birth_date?(text, today)
      found << "email" if text.match?(EMAIL)
      found << "label" if text.match?(LABELS)
      found << "name" if name_left?(text, names)
      found
    end

    def birth_date?(text, today)
      text.each_line.any? { |line| birth_date_line?(line.strip, today) }
    end

    # A date "Place, <date>" at the start of a line is always a birth date (F-25), whatever follows
    # ("Bandung, 12-03-1995 – sekarang"). Next to lahir/born/TTL/usia: birth date. On a line with a
    # work marker, or forming a range of two dates: work. Anything else: a finding (fail closed).
    def birth_date_line?(line, today)
      place_date = line.match?(PLACE_DATE_LINE)
      full = FULL_DATES.flat_map { |pattern| line.scan(pattern).map { |groups| year_of(groups, today) } }.compact
      # Month-years that are not already part of a full date ("12 Maret 1995" is ONE date).
      rest = FULL_DATES.reduce(line) { |acc, pattern| acc.gsub(pattern, " ") }
      month_years = rest.scan(MONTH_YEAR).map { |(y)| full_year(y, today) }
      candidates = place_date ? full + month_years : full
      return false unless candidates.any? { |y| y.between?(1950, today.year - 15) }
      return true if place_date || line.match?(BIRTH_CONTEXT)

      range = (full.size + month_years.size) >= 2
      !(range || line.match?(WORK_MARKER))
    end

    def year_of(groups, today)
      four = groups.find { |g| g.length == 4 }
      return four.to_i if four

      full_year(groups.last, today)
    end

    # '95 -> 1995, '09 -> 2009 (a two-digit year is read as the most recent past year).
    def full_year(digits, today)
      return digits.to_i if digits.length == 4

      year = 2000 + digits.to_i
      year > today.year ? year - 100 : year
    end

    # The evidence floor (F-23, F-28, F-34): fewer than EVIDENCE_FLOOR_WORDS real-looking words
    # outside markers and heading-shaped lines means the CV would be judged on (almost) nothing, so a
    # person looks. A word counts when it has 3+ letters, contains a vowel, is not one letter
    # repeated, and is not a run of consecutive alphabet letters ("abc", "jkl"): F-34 showed
    # "abc def ghi jkl" passing a plain word count. 4, because the shortest real CV body in the
    # engine's suites ("2017 - 2024 Admin Gudang di PT Logistik Makmur") has exactly four such words
    # (Admin, Gudang, Logistik, Makmur); filler or a closing line has fewer.
    EVIDENCE_FLOOR_WORDS = 4

    def too_little_text?(text)
      body = text.each_line.reject { |l| Redactor.heading_shaped?(l.strip) }.join.gsub(Redactor::MARK, " ")
      body.scan(/[[:alpha:]]{3,}/).count { |w| wordlike?(w) } < EVIDENCE_FLOOR_WORDS
    end

    def wordlike?(word)
      w = word.downcase
      return false unless w.match?(/[aeiouy]/)
      return false if w.chars.uniq.size == 1

      w.chars.each_cons(2).any? { |a, b| b.ord != a.ord + 1 }
    end

    def name_left?(text, names)
      words = names.compact.flat_map { |n| n.to_s.split(/\s+/) }.select { |w| w.length >= 3 }
      words.any? { |w| text.match?(/(?<![[:alpha:]])#{Regexp.escape(w)}(?![[:alpha:]])/i) }
    end

    def label_for(keys) = keys.map { |k| CATEGORIES.fetch(k) }.join(", ")
  end
end
