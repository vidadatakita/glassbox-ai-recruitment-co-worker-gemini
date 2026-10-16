module Screening
  # D51 A (feature 09): before redaction, keep ONLY the CV's evidence sections: experience,
  # education, skills, certifications and training (Redactor::SEND_HEADING). Everything else is
  # dropped before the text is even redacted: the untitled header (name, contacts, birth data), the
  # summary or profile, hobbies, family, references, personal-data sections.
  #
  # Why: engine run 5 planted nine protected sentences and eight reached the request body (ADR
  # 0004, run-5 ledger). Dropping non-evidence sections removes most of the places such sentences
  # live; it does NOT catch one written inside an experience section, which is why D51 adds the
  # human release (B) after this step, and keeps redaction and the residual check (C).
  #
  # A section starts at a send heading and ends at the next KNOWN heading of another kind
  # (Redactor.section_kind). Unknown headings do not end it (see Redactor::OTHER_HEADING for why).
  # The heading lines themselves are kept, so the model and the reviewer see which section a line
  # belongs to.
  #
  # Returns the kept text, or nil when no evidence section is recognised: then nothing is sent and
  # the CV goes to a person ("Perlu cek manual: Bagian pengalaman/pendidikan tidak ditemukan").
  module EvidenceSections
    module_function

    # groups: the CV parts the setting allows (Screening::CvSections). A heading of an allowed group
    # starts keeping; a heading of any other known section (another group, personal data, hobbies,
    # references...) stops it; an unknown heading changes nothing (see Redactor::OTHER_HEADING).
    def keep(text, groups: CvSections.enabled)
      keeping = false
      found = false
      kept = text.to_s.gsub("\r\n", "\n").split("\n", -1).select do |line|
        group = CvSections.group_of(line)
        if group
          keeping = groups.include?(group)
          found ||= keeping
        elsif Redactor.section_kind(line.strip)
          keeping = false
        end
        keeping
      end
      return nil unless found

      kept.join("\n").strip
    end
  end
end
