module ScreeningReport
  # Test engine 08 run 1 F-01 (D62 h7): the report prints text the AI returned (Posisi Terakhir, the
  # education and experience facts, every CV quote, the narrative claims, the label reason). Redaction
  # before the call can miss a header line (engine run 5: 8 of 9 planted sentences reached the model),
  # so the model can echo the candidate's own name, email or phone. For a viewer from whom
  # CandidateIdentity hides identity, every such text passes through THIS mask before it is rendered,
  # on screen and in both xlsx sheets:
  #   - this application's name: the whole name, each word of 3+ letters, and the words joined with
  #     ".", "_" or "-" (as in handles) — whole words, case-insensitive -> "[nama]"
  #   - any email address and any phone-shaped number (9+ digits with +62/62/0 prefixes), and this
  #     candidate's own email and phone exactly -> "[kontak]"
  # Display only: quote verification ran on the unmasked text when the result was stored, and the
  # stored rows are never changed. Over-masking is accepted: a short name word that is also an
  # ordinary word ("Uji") is masked wherever it appears, because a blind view must not leak.
  class IdentityMask
    NAME = "[nama]".freeze
    CONTACT = "[kontak]".freeze
    EMAIL = /[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/
    PHONE = /(?<!\d)(?:\+?62|0)[\d\s().-]{7,18}\d(?!\d)/

    def initialize(candidate)
      @email = candidate&.email.to_s.strip
      @phone = candidate&.phone.to_s.strip
      @names = name_patterns(candidate&.name.to_s)
    end

    def call(text)
      return text if text.nil?

      masked = text.to_s.gsub(EMAIL, CONTACT).gsub(PHONE, CONTACT)
      [@email, @phone].reject { |v| v.length < 5 }.each { |v| masked = masked.gsub(/#{Regexp.escape(v)}/i, CONTACT) }
      @names.reduce(masked) { |out, pattern| out.gsub(pattern, NAME) }
    end

    private

    def name_patterns(name)
      tokens = name.split(/\s+/).reject(&:empty?)
      joined = tokens.size > 1 ? %w[. _ -].map { |glue| tokens.join(glue) } : []
      words = tokens.select { |t| t.length >= 3 }
      ([name.strip] + joined + words).reject(&:empty?).uniq.sort_by { |n| -n.length }.map do |n|
        /(?<![[:alpha:]])#{Regexp.escape(n)}(?![[:alpha:]])/i
      end
    end
  end
end
