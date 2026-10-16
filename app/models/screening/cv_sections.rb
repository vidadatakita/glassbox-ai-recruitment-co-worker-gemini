module Screening
  # Which parts of a CV may go to the AI: a screen setting (Pengaturan Sistem, "ai_cv_sections"),
  # so the client decides, not the code. Each group is recognised by its heading. The default is
  # the D51 A list (experience, education, skills, certifications and training).
  #
  # Personal data can never be chosen: a personal-data section (Redactor::PERSONAL_HEADING) is not
  # a group, and everything that IS sent is still redacted (name, birth date, address, NIK, phone,
  # email, religion, marital status...) and residual-checked (Screening::ReleaseGate).
  module CvSections
    LEAD = '\A[\s\-•*\d.)]*'
    TAIL = '\s*:?\s*\z'
    def self.heading(words) = Regexp.new("#{LEAD}(?:#{words})#{TAIL}", Regexp::IGNORECASE)

    GROUPS = {
      "experience" => ["Pengalaman kerja", heading('pengalaman(?:\s+(?:kerja|profesional|bekerja))?|riwayat\s+(?:pekerjaan|kerja|karir|karier)|karir|karier|jenjang\s+karir|work\s+(?:experience|history)|professional\s+experience|experience|employment(?:\s+history)?|career(?:\s+history)?')],
      "education" => ["Pendidikan", heading('pendidikan(?:\s+(?:formal|terakhir|non\s*formal))?|riwayat\s+pendidikan|education(?:al\s+background)?')],
      "skills" => ["Keahlian", heading('keahlian|kemampuan|keterampilan|skills?|kompetensi|technical\s+skills')],
      "certifications" => ["Sertifikasi dan pelatihan", heading('sertifikasi|sertifikat|certifications?(?:\s*&\s*training)?|certificates?|lisensi|licen[sc]es?|pelatihan|training|kursus|courses?')],
      "projects" => ["Proyek dan portofolio", heading('proyek|projects?|portofolio|portfolio')],
      "activities" => ["Organisasi, prestasi, dan bahasa", heading('organisasi|organi[sz]ations?|prestasi|achievements?|penghargaan|awards?|bahasa|languages?')],
      "summary" => ["Ringkasan atau profil", heading('ringkasan(?:\s+profil)?|(?:professional\s+|profile\s+)?summary|profil(?:\s+(?:singkat|profesional))?|profile|tentang\s+saya|about\s+me|objective')]
    }.freeze
    DEFAULT = Glassbox::Settings::SCREEN_KEYS.fetch("ai_cv_sections")[:default].freeze

    module_function

    def label(key) = GROUPS.fetch(key).first

    # The group a heading line opens, or nil.
    def group_of(line)
      text = line.to_s.strip
      GROUPS.find { |_, (_, pattern)| text.match?(pattern) }&.first
    end

    def enabled(company: nil) = Array(SystemSetting.value_of("ai_cv_sections", company:)).presence || DEFAULT
  end
end
