module Screening
  # Blueprint §4.1 step 3 and §4.2: before any CV text leaves the portal, remove the name, the
  # photo, the date of birth and age, gender, religion, marital status, and address detail below
  # city level. Pattern-based and imperfect, as the spec says; §5.1 row 2 tests it on fixture CVs
  # in Indonesian formats, asserting on the OUTGOING request body.
  #
  # Policy: over-redact rather than under-redact, EXCEPT for two things the screening needs:
  #   - the CITY of an address stays (the spec removes detail BELOW city level; placement and
  #     relocation requirements are judged on it), so an address value keeps only its last
  #     comma-separated part when that part looks like a place name;
  #   - a line that merely starts with a generic word ("Status : Karyawan tetap") stays; only the
  #     marital-status labels and marital words go.
  # A removed fact that was evidence costs a reviewer look (the quote check cannot find a quote
  # that is only a marker); a protected attribute that reaches the model is the expensive failure
  # §5.1 row 2 exists to stop. Test engine run 1 (F-01, F-02, F-06) drove the second version of
  # these patterns; its variant CVs are in test/engine/screening/redaction_outgoing_body_test.rb.
  #
  # The photo needs no rule: only extracted TEXT is ever sent (Screening::Run); images in the PDF
  # are never read, so no picture can leave.
  #
  # Also removed, beyond the spec's list, because Indonesian CVs commonly carry them and they are
  # protected or identifying: NIK / KTP number, email, phone, profile links, ethnicity (suku),
  # height, weight, blood type.
  class Redactor
    MARK = "[REDACTED]".freeze
    Result = Data.define(:text, :counts)

    SEP = /\s*(?::|：|\t|-\s|–|\s{2,}|\z)/

    # Labels whose WHOLE LINE is removed when the line starts with them (after a bullet or spaces)
    # and a separator follows. Generic "Status" is NOT here (F-06); its marital forms are.
    LINE_LABELS = [
      /nama(?:\s+(?:lengkap|panggilan))?/, /(?:full\s+)?name/,
      /tempat\s*(?:[\/,&]|dan)?\s*(?:tgl|tanggal)\.?\s*lahir/, /(?:tgl|tanggal)\.?\s*lahir/, /tempat\s+lahir/, /lahir/, /ttl/,
      /(?:place\s*(?:and|&|\/)?\s*)?date\s+of\s+birth/, /birth\s*date/, /dob/, /born/,
      /usia/, /umur/, /age/,
      /jenis\s*kelamin/, /kelamin/, /gender/, /sex/,
      /agama/, /religion/,
      /status\s+(?:pernikahan|perkawinan|marital|sipil|nikah|pajak|ptkp)/, /marital\s+status/, /npwp/, /kelahiran/,
      /kode\s*pos/, /rt\s*\/\s*rw/,
      /nik/, /no\.?\s*ktp/, /nomor\s+ktp/, /ktp/, /suku(?:\s+bangsa)?/, /ethnicity/,
      /tinggi\s*badan/, /berat\s*badan/, /tinggi\s*\/\s*berat\s*badan/, /golongan\s+darah/,
      /e-?mail/, /surel/, /(?:no\.?\s*)?(?:telepon|telp|tlp|hp|handphone|whatsapp|wa)(?:\s*\/\s*(?:wa|hp))?/, /phone/, /mobile/
    ].freeze
    LINE_LABEL_RE = /\A[\s\-•*·▪●–]*(?:#{LINE_LABELS.map(&:source).join('|')})#{SEP.source}/i

    # Labels specific enough to remove from the label to the END of the line wherever they occur,
    # with or without a separator: two-column layouts ("Pendidikan: S1    Agama: Islam") and
    # unlabelled forms ("Usia 27 tahun", "Born in Surabaya on 2 May 1990", "Suku Jawa").
    INLINE_LABELS = Regexp.union(
      /(?:tempat\s*(?:[\/,&]|dan)?\s*)?(?:tgl|tanggal)\.?\s*lahir.*/i, /\btempat\s+lahir.*/i, /\blahir\b.*/i,
      /\bkelahiran\b.*/i, /\bttl\b.*/i, /\bdob\b.*/i, /\bborn\b.*/i, /date\s+of\s+birth.*/i,
      /\bnpwp\b.*/i, /\bstatus\s+(?:pajak|ptkp)\b.*/i, /\bptkp\b.*/i, /\b(?:nik|no\.?\s*ktp|nomor\s+ktp)\b.*/i,
      # F-32: up to three words may sit between the word and the number ("Umur saya 27 tahun",
      # "Berusia 30-an"), and a decade ("30-an") is an age too.
      /\b(?:usia|umur|berusia|berumur|aged?)\b(?:\s+[[:alpha:]]+){0,3}?\s*[:.\-]?\s*\d{1,3}.*/i,
      /\bagama\b.*/i, /\breligion\b.*/i, /jenis\s*kelamin.*/i,
      /status\s+(?:pernikahan|perkawinan|nikah)\b.*/i, /marital\s+status.*/i,
      /\bsuku(?:\s+bangsa)?\b.*/i, /\b(?:etnis|etnik|keturunan|berdarah|ras)\b.*/i, /\bkepercayaan\b.*/i,
      /\btanggungan\b.*/i,
      /\b(?:tinggi|berat|tb|bb)(?:\s*badan)?\s*[:=]?\s*\d{2,3}\b.*/i, /\btinggi\s*(?:\/\s*berat\s*)?badan\b.*/i, /\bberat\s*badan\b.*/i, /\bgolongan\s+darah\b.*/i
    )

    # Address labels: the value keeps only its city (see class comment).
    ADDRESS_LABEL = /\A(?<lead>[\s\-•*·]*(?:alamat(?:\s+(?:rumah|domisili|ktp|tinggal|lengkap|sekarang))?|domisili|tempat\s+tinggal|address|residence)\s*(?::|：|-\s|–|\s)\s*)(?<value>.*)\z/i

    # Street-level address lines and fragments (below city level), labelled or not.
    STREET = /\b(?:jl|jln|jalan|gg|gang|rt|rw|kel|kelurahan|kec|kecamatan|desa|ds|dusun|dsn|dukuh|kp|kampung|lingk|lingkungan|asrama|mess|kos|kost|blok|komp|komplek|kompleks|perum|perumahan|cluster|no|kode\s*pos)\b/i
    ADDRESS_LINE = /\A[\s\-•*·]*(?:jl\.?|jln\.?|jalan|gg\.?|gang|rt\.?\s*\d|rw\.?\s*\d|kel\.|kelurahan|kec\.|kecamatan|desa|ds\.|dusun|dsn\.|dukuh|kp\.|kampung|lingk\.|lingkungan|blok|komp\.|komplek|kompleks|perum\.?|perumahan|no\.\s*\d|kode\s*pos)(?![[:alnum:]]).*\z/i
    # F-31: Kel./Kec./Kelurahan/Kecamatan anywhere in a line is an address below city level.
    ADDRESS_FRAGMENT = /\b(?:kel|kec)\.\s*.*|\b(?:kelurahan|kecamatan)\s+(?-i:[A-Z]).*|\b(?:jl|jln)\.?\s+.*|\bjalan\s+[A-Z].*|\bgg\.\s*.*|\b(?:kp|ds|dsn|lingk)\.\s*(?-i:[A-Z]).*|\b(?:kampung|lingkungan|dukuh|desa|dusun|gang)\s+(?-i:[A-Z]).*|\b(?:perum|perumahan|komp|komplek|kompleks)\.?\s+[A-Z].*|\bRT\.?\s*\d{1,3}\s*\/?\s*RW\.?\s*\d{1,3}.*|\bRT\.?\s*\d{1,3}\b.*/i

    EMAIL = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i
    # "ina.p95(at)gmail(dot)com", "nama [at] gmail", "nama at gmail dot com".
    EMAIL_OBFUSCATED = Regexp.union(
      /[A-Z0-9._%+\-]+\s*(?:\(at\)|\[at\]|\{at\})\s*[A-Z0-9\-]+(?:\s*(?:\(dot\)|\[dot\]|\{dot\}|\.|\s+dot\s+)\s*[A-Z]{2,})*/i,
      # " at " only before a mail provider, so "Supervisor at PT ..." is untouched.
      /[A-Z0-9._%+\-]+\s+at\s+(?:gmail|yahoo|ymail|hotmail|outlook|live|icloud|mail)\b(?:\s*(?:\.|\s+dot\s+)\s*[A-Z]{2,})*/i
    )
    # Ethnic group names after "orang" or followed by "asli" (they are also place names, so not alone),
    # and the names that are never a place.
    ETHNIC_NAMES = "tionghoa|cina|china|batak|jawa|sunda|minang|minangkabau|bugis|makassar|betawi|madura|dayak|banjar|bali|sasak|ambon|manado|minahasa|toraja|aceh|melayu|nias|papua|flores|timor|arab|india".freeze
    ETHNIC = /\borang\s+(?:#{ETHNIC_NAMES})\b(?:\s+asli)?|\b(?:#{ETHNIC_NAMES})\s+asli\b|\btionghoa\b/i
    PROFILE_URL = %r{(?:https?://)?(?:www\.)?(?:linkedin\.com|instagram\.com|github\.com|facebook\.com|fb\.com|twitter\.com|x\.com|tiktok\.com|t\.me)/\S*}i
    HANDLE = /(?<![\w@])@[A-Za-z0-9_.]{3,}/
    # NIK / KTP: 16 digits, also printed in groups of four.
    NIK = /(?<![\d])\d{4}[\s.\-]?\d{4}[\s.\-]?\d{4}[\s.\-]?\d{4}(?![\d])/
    # Mobile and landline numbers: +62 / 62 / 0 prefix, an optional bracketed area code, groups
    # separated by a space, dot or dash. At least 9 digits, so a date such as 03-07-1994 (8 digits)
    # or a year range is not mistaken for a phone (dates near "lahir" are removed by their label).
    PHONE = /(?<![\d\w])(?:\+?62[\s.\-]?\(?\d{2,4}\)?|\(?0\d{1,4}\)?)(?:[\s.\-]?\d{2,5}){1,4}(?![\d])/
    MIN_PHONE_DIGITS = 9
    # Unlabelled values. Religion words also hit institution names ("Universitas Islam ..."), which
    # is wanted: the institution name signals the religion just the same.
    RELIGION = /\b(?:islam|muslim|muslimah|moslem|kristen|kristiani|nasrani|protestan|katolik|katholik|hindu|buddha|budha|buddhis|konghucu|khonghucu|kong\s*hu\s*cu|khong\s*hu\s*cu|kejawen|aliran\s+kepercayaan|penghayat|berhijab|hijab|berjilbab|jilbab)\b/i
    MARITAL = /\b(?:belum\s+menikah|sudah\s+menikah|menikah|belum\s+kawin|tidak\s+kawin|kawin|lajang|bujang|perawan|gadis|(?:sudah\s+)?berkeluarga|cerai(?:\s+(?:hidup|mati))?|janda|duda|married|unmarried|divorced|widowed|widow|widower)\b/i
    # PTKP tax codes reveal marital status and dependants: K/1, TK/0, K/I/2, HB/0.
    TAX_STATUS = %r{\b(?:TK|K|HB|K\s*/\s*I)\s*/\s*\d\b}
    # A "Status" line whose value is a marital term in any language ("Status: Single"). A generic
    # "Status : Karyawan tetap" line is NOT touched (F-06); "single" alone elsewhere is ordinary text.
    STATUS_MARITAL_LINE = %r{\A[\s\-•*]*status\b[^\n]*?(?:\bsingle\b|\bmarried\b|\bmenikah\b|\bkawin\b|\blajang\b|\bcerai\b|\b(?:TK|K|HB)(?:\s*/\s*\d)?\s*\z)}i
    NPWP = /(?<!\d)\d{2}\.?\d{3}\.?\d{3}\.?\d[\-.]?\d{3}\.?\d{3}(?!\d)/
    GENDER = /\b(?:laki-laki|laki\s+laki|perempuan|pria|wanita|cewek|cewe|cowok|cowo|male|female|(?:ibu|bapak)\s+rumah\s+tangga)\b/i
    # English gender pronouns and religion words are removed EVERYWHERE, evidence sections included
    # (GlassBox Team decision, 16 Oct 2026): an English CV says "She led the team" or "Christian
    # University" inside WORK EXPERIENCE / EDUCATION, where the Indonesian word lists above are
    # switched off (F-27), and the fairness check showed those words reaching the model. Word-bounded
    # and case-insensitive, so "Hermawan", "Shelly", "Templeton" and "promoted" are untouched.
    # Indonesian has no gendered pronoun, so this list has no Indonesian counterpart.
    PRONOUN_EN = /\b(?:he|she|his|her|him|hers|himself|herself)\b/i
    RELIGION_EN = /\b(?:christian|catholic|protestant|muslim|islamic|buddhist|hindu|church|mosque|temple)\b/i
    # "L/P : P" style gender fields.
    GENDER_FIELD = %r{\bL\s*/\s*P\b.*}i
    # Ages in any common unit, bracketed or after "usia/umur" (handled above); and body measures.
    # Ages: unambiguous English forms anywhere. "(8 tahun)" after a job title is experience, not an
    # age (F-12), so an Indonesian bracketed number is removed only right after a removed name
    # ("[REDACTED] (28)", "[REDACTED] (29 tahun)"), see AGE_AFTER_NAME.
    AGE = /\(\s*\d{1,3}\s*(?:years?|yrs?|y\.?o\.?)\s*\)|\b\d{1,3}\s*(?:years?|yrs?)\s+old\b|\b\d{1,3}\s*y\.?o\b/i
    AGE_AFTER_NAME = /(?<=\[REDACTED\])[ \t]*,?[ \t]*\(?[ \t]*\d{1,3}[ \t]*(?:tahun|thn|th)?[ \t]*\)?(?=[ \t]|,|$)/i
    # Height and weight only next to their label (TB/BB, tinggi/berat, height/weight); "beban 25 kg"
    # or "rak setinggi 300 cm" is job evidence (F-12).
    BODY = /\b(?:tb|bb|tinggi(?:\s*badan)?|berat(?:\s*badan)?|height|weight)\b\s*[:=]?\s*\d{2,3}(?:[.,]\d)?\s*(?:cm|kg)\b/i

    def self.call(text, names: []) = new(names:).call(text)

    # names: the candidate's own name(s) from the application. Removed exactly, whole name first,
    # then each word of three letters or more anywhere in the text, and the words run together
    # ("rinapratiwi", "rina.pratiwi", "rina_pratiwi") as used in profile links and handles.
    def initialize(names: [])
      parts = names.compact.map { |n| n.to_s.strip }.reject(&:empty?)
      words = parts.flat_map { |n| n.split(/\s+/) }.select { |w| w.length >= 3 }
      @joined = parts.flat_map do |n|
        tokens = n.split(/\s+/)
        tokens.size > 1 ? ["", ".", "_", "-"].map { |glue| tokens.join(glue) } : []
      end
      # The glued-without-separator form ("analisa" from "Ana Lisa", "diantara" from "Dian Tara") is
      # an ordinary word for some names (F-13), so it is removed only inside a link-like token
      # (one holding "/", "@", "www" or a domain); the forms with ".", "_" or "-" are removed as
      # whole words anywhere.
      @glued = @joined.select { |n| n.match?(/\A[[:alpha:]]+\z/) }
      separated = @joined - @glued
      @name_patterns = (separated + parts.sort_by { |n| -n.length } + words.uniq).uniq.map do |n|
        /(?<![[:alpha:]])#{Regexp.escape(n)}(?![[:alpha:]])/i
      end
    end

    # Structural layer 1 (ADR 0004): a section the CV itself titles as personal data ("Data
    # Pribadi", "Biodata", "Personal Details", "Kontak", ...) is dropped whole, up to the next known
    # section heading, whatever its lines look like. Only explicitly titled sections: dropping the
    # unlabelled header above the first heading was rejected, because that header often carries
    # evidence ("Status : Karyawan tetap di PT ...", a summary), see the ADR.
    PERSONAL_HEADING = /\A[\s\-•*\d.)]*(?:data\s+(?:pribadi|diri)|biodata(?:\s+diri)?|identitas(?:\s+diri)?|informasi\s+(?:pribadi|kontak)|personal\s+(?:data|details|information|info|particulars)|kontak|contact(?:\s+(?:information|details|info))?)\s*:?\s*\z/i
    SECTION_HEADING = /\A[\s\-•*\d.)]*(?:pengalaman(?:\s+(?:kerja|profesional|organisasi))?|riwayat\s+(?:pekerjaan|kerja|pendidikan)|work\s+(?:experience|history)|professional\s+experience|experience|employment(?:\s+history)?|pendidikan(?:\s+(?:formal|terakhir|non\s*formal))?|education|ringkasan(?:\s+profil)?|(?:professional\s+|profile\s+)?summary|profil(?:\s+(?:singkat|profesional))?|profile|tentang\s+saya|about\s+me|objective|keahlian|kemampuan|keterampilan|skills?|kompetensi|sertifikasi|sertifikat|certifications?|pelatihan|training|kursus|organisasi|bahasa|languages?|proyek|projects?|prestasi|achievements?|penghargaan|referensi|references)\s*:?\s*\z/i

    # Evidence sections (test engine run 4, F-27): experience, education, skills, certifications,
    # training, organisations, projects, achievements, languages. Inside them the protected WORD
    # lists (religion, marital, gender, ethnicity) and the village/housing phrases do not apply:
    # "Kawin silang ternak sapi", "Kasir di Toko Gadis Mart", "Lingkungan kerja K3" are evidence.
    # Labels, identifiers, phones, emails, names and street addresses with RT/RW still go
    # everywhere. Everything else (the header, summary/profile, references, unknown headings) is
    # personal context, where the word lists apply.
    EVIDENCE_HEADING = /\A[\s\-•*\d.)]*(?:pengalaman(?:\s+(?:kerja|profesional|organisasi))?|riwayat\s+(?:pekerjaan|kerja|pendidikan)|work\s+(?:experience|history)|professional\s+experience|experience|employment(?:\s+history)?|pendidikan(?:\s+(?:formal|terakhir|non\s*formal))?|education|keahlian|kemampuan|keterampilan|skills?|kompetensi|sertifikasi|sertifikat|certifications?|pelatihan|training|kursus|organisasi|bahasa|languages?|proyek|projects?|prestasi|achievements?|penghargaan)\s*:?\s*\z/i

    # D51 A (feature 09): the ONLY sections whose content is ever sent to the AI. Experience
    # (pengalaman kerja, riwayat pekerjaan, karir), education (pendidikan), skills (keahlian,
    # kemampuan), certifications (sertifikasi, lisensi) and training (pelatihan, kursus). Narrower
    # than EVIDENCE_HEADING on purpose: organisations, projects, achievements and languages are
    # evidence for redaction context (F-27) but are NOT in GlassBox Team's D51 list, so they are not sent.
    # Kept separate from EVIDENCE_HEADING so adding "karir" / "lisensi" here does not change the
    # redaction context the feature-06 engine tests pin.
    SEND_HEADING = /\A[\s\-•*\d.)]*(?:pengalaman(?:\s+(?:kerja|profesional|bekerja))?|riwayat\s+(?:pekerjaan|kerja|karir|karier|pendidikan)|karir|karier|jenjang\s+karir|work\s+(?:experience|history)|professional\s+experience|experience|employment(?:\s+history)?|career(?:\s+history)?|pendidikan(?:\s+(?:formal|terakhir|non\s*formal))?|education(?:al\s+background)?|keahlian|kemampuan|keterampilan|skills?|kompetensi|sertifikasi|sertifikat|certifications?|certificates?|lisensi|licen[sc]es?|pelatihan|training|kursus|courses?)\s*:?\s*\z/i
    # Known headings of sections that are NOT sent: a send section ends at one of these (or at any
    # personal-data heading or other known section heading). Unknown headings do NOT end a send
    # section: an all-capitals employer or job title ("PT LOGISTIK MAKMUR", "ADMIN GUDANG") is
    # heading-shaped, and ending the experience section there would silently drop evidence. What an
    # unknown heading lets through is seen by the reviewer before anything is sent (D51 B).
    OTHER_HEADING = /\A[\s\-•*\d.)]*(?:hobi|hobby|hobbies|minat|interests?|kegiatan\s+lain|lain-lain|informasi\s+tambahan|additional\s+information|keterangan\s+lain|motto|moto|kepribadian|personality|karakter|kelebihan|kekurangan|keluarga|data\s+keluarga|family|referensi|references?|organisasi|organi[sz]ations?|bahasa|languages?|proyek|projects?|prestasi|achievements?|penghargaan|awards?|publikasi|publications?|surat\s+pernyataan|pernyataan|declaration)\s*:?\s*\z/i

    # :send, :other (a known heading of a section that is not sent) or nil (not a section boundary).
    def self.section_kind(line)
      text = line.to_s
      return :send if text.match?(SEND_HEADING)
      return :other if text.match?(PERSONAL_HEADING) || text.match?(SECTION_HEADING) || text.match?(OTHER_HEADING)

      nil
    end

    def call(text)
      counts = Hash.new(0)
      lines = drop_personal_sections(text.to_s.gsub("\r\n", "\n").split("\n", -1), counts)
      context = :personal
      lines = lines.map do |line|
        if line.match?(EVIDENCE_HEADING)
          context = :evidence
        elsif self.class.heading_shaped?(line) && !personal_line?(line)
          context = :personal
        end
        redact_words(redact_line(line, counts, context), counts, context)
      end
      Result.new(text: lines.join("\n"), counts: counts.to_h)
    end

    # Identifiers, contacts, names, label-bound values, English pronouns and English religion words:
    # everywhere. The Indonesian protected word lists: only in personal context (F-27), and only the
    # word itself is replaced.
    def redact_words(line, counts, context)
      out = sub_count(line, EMAIL, counts, :email)
      out = sub_count(out, EMAIL_OBFUSCATED, counts, :email)
      out = sub_count(out, PROFILE_URL, counts, :profile)
      out = sub_count(out, HANDLE, counts, :profile)
      out = sub_count(out, NIK, counts, :nik)
      out = out.gsub(PHONE) do |match|
        next match if match.scan(/\d/).size < MIN_PHONE_DIGITS

        counts[:phone] += 1
        MARK
      end
      out = redact_glued_names(out, counts)
      @name_patterns.each { |pattern| out = sub_count(out, pattern, counts, :name) }
      out = sub_count(out, TAX_STATUS, counts, :marital)
      out = sub_count(out, NPWP, counts, :npwp)
      out = sub_count(out, AGE_AFTER_NAME, counts, :age)
      out = sub_count(out, GENDER_FIELD, counts, :gender)
      out = sub_count(out, AGE, counts, :age)
      out = sub_count(out, BODY, counts, :body)
      out = sub_count(out, PRONOUN_EN, counts, :gender)
      out = sub_count(out, RELIGION_EN, counts, :religion)
      return out if context == :evidence

      out = sub_count(out, RELIGION, counts, :religion)
      out = sub_count(out, MARITAL, counts, :marital)
      out = sub_count(out, GENDER, counts, :gender)
      sub_count(out, ETHNIC, counts, :ethnicity)
    end

    private

    # In evidence context a village/housing marker counts only in an address-shaped line (it also
    # carries RT/RW, Kel./Kec., a house number or Jl.): "Gang supervisor shift malam" stays.
    ADDRESS_SHAPED = /\b(?:RT|RW)\.?\s*\d|\b(?:kel|kec)\.|\bkelurahan\b|\bkecamatan\b|\bno\.\s*\d|\bjl\.?\s|\bjln\b|\bblok\s+[A-Z0-9]/i
    PERSONAL_PHRASES = Regexp.union(/\btinggal\s+di\b.*/i, /\b(?:asrama|mess|kos|kost|indekos)\s+(?-i:[A-Z]).*/i)
    STRICT_FRAGMENT = /\b(?:jl|jln)\.?\s+.*|\bRT\.?\s*\d{1,3}\s*\/?\s*RW\.?\s*\d{1,3}.*/i

    def redact_line(line, counts, context = :personal)
      if (address = line.match(ADDRESS_LABEL))
        counts[:address] += 1
        return "#{address[:lead]}#{city_only(address[:value])}"
      end
      if line.match?(LINE_LABEL_RE) || line.match?(STATUS_MARITAL_LINE)
        counts[:labelled_line] += 1
        return MARK
      end
      if line.match?(ADDRESS_LINE) && (context == :personal || line.match?(ADDRESS_SHAPED))
        counts[:address] += 1
        return MARK
      end
      line = sub_count(line, INLINE_LABELS, counts, :labelled_line)
      if context == :evidence
        # An address-shaped line (RT/RW, Kel./Kec., No., Jl.) loses its village/street phrase even here.
        return sub_count(line, line.match?(ADDRESS_SHAPED) ? ADDRESS_FRAGMENT : STRICT_FRAGMENT, counts, :address)
      end

      line = sub_count(line, PERSONAL_PHRASES, counts, :address)
      sub_count(line, ADDRESS_FRAGMENT, counts, :address)
    end

    # F-23: a personal section ends at ANY heading-shaped line, not only a known heading, so an
    # unknown heading ("RIWAYAT KARIR") never makes the rest of the CV disappear. A heading-shaped
    # line that is itself a personal label ("Alamat:") or holds the candidate's name does not end it.
    def drop_personal_sections(lines, counts)
      dropping = false
      lines.filter_map do |line|
        if line.match?(PERSONAL_HEADING)
          dropping = true
          counts[:personal_section] += 1
          MARK
        elsif dropping && self.class.heading_shaped?(line) && !personal_line?(line)
          dropping = false
          line
        else
          dropping ? nil : line
        end
      end
    end

    # A known section heading; a numbered short line ("2. PENGALAMAN KERJA"); an all-capitals short
    # line ("RIWAYAT KARIR"); or a short line ending with ":" ("Riwayat Karir:").
    def self.heading_shaped?(line)
      text = line.to_s.strip
      return false if text.empty? || text == MARK
      return true if text.match?(SECTION_HEADING) || text.match?(PERSONAL_HEADING)

      words = text.split(/\s+/).size
      return false if words > 6
      return true if text.match?(/\A\d{1,2}[.)]\s+\S/)
      return true if text.end_with?(":") && words <= 5

      letters = text.scan(/[[:alpha:]]/)
      letters.size >= 4 && letters.none? { |c| c.match?(/[[:lower:]]/) }
    end

    # F-26: a line made only of protected words ("ISLAM", "MENIKAH", "PRIA, BELUM MENIKAH") is
    # personal, not a heading, so it never ends a personal section.
    def personal_line?(line)
      return true if line.match?(LINE_LABEL_RE) || line.match?(ADDRESS_LABEL) || line.match?(INLINE_LABELS)
      return true if @name_patterns.any? { |p| line.match?(p) }

      rest = [RELIGION, MARITAL, GENDER, ETHNIC].reduce(line) { |acc, re| acc.gsub(re, "") }
      rest.gsub(/[[:punct:][:space:]]/, "").empty? && line.match?(/[[:alpha:]]/)
    end

    LINK_TOKEN = %r{\S*(?:/|@|www\.|\.(?:com|id|net|org|me|io|co)\b)\S*}i

    def redact_glued_names(text, counts)
      return text if @glued.empty?

      pattern = Regexp.union(@glued.map { |n| /#{Regexp.escape(n)}/i })
      text.gsub(LINK_TOKEN) do |token|
        next token unless token.match?(pattern)

        counts[:name] += 1
        MARK
      end
    end

    # "Jl. Kenanga No. 12 RT 004/RW 009, Kel. Margahayu, Bekasi" -> "[REDACTED], Bekasi";
    # "Purwakarta" -> "Purwakarta"; anything without a clean last part -> "[REDACTED]".
    def city_only(value)
      segments = value.split(",").map(&:strip).reject(&:empty?)
      return MARK if segments.empty?

      city = segments.last
      clean = !city.match?(/\d/) && !city.match?(STREET) && city.split(/\s+/).size <= 3
      return MARK unless clean
      return city if segments.size == 1

      "#{MARK}, #{city}"
    end

    def sub_count(text, pattern, counts, key)
      text.gsub(pattern) do
        counts[key] += 1
        MARK
      end
    end
  end
end
