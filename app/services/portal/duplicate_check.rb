module Portal
  # AI Builder Cup step 04, "flags duplicates": other applications of the same person within the same
  # client company, by rule: the same email, the same phone number (digits only), or the very same CV
  # file (ActiveStorage checksum). Not the AI: telling people apart needs names and contacts, which
  # the AI never sees (guardrail). A flag is information for staff; nothing is merged or refused.
  module DuplicateCheck
    Match = Data.define(:application, :reasons)

    module_function

    def for(application)
      others = JobApplication.joins(:job, :candidate).where(jobs: { client_company_id: application.job.client_company_id })
                             .where.not(id: application.id).includes(:job, :candidate).to_a
      candidate = application.candidate
      return [] unless candidate

      email = candidate.email.to_s.downcase.strip
      phone = digits(candidate.phone)
      checksum = application.cv.attached? ? application.cv.blob.checksum : nil
      others.filter_map do |other|
        reasons = []
        reasons << "same email" if email.present? && other.candidate&.email.to_s.downcase.strip == email
        reasons << "same phone number" if phone.length >= 8 && digits(other.candidate&.phone) == phone
        reasons << "same CV file" if checksum && other.cv.attached? && other.cv.blob.checksum == checksum
        Match.new(other, reasons) if reasons.any?
      end
    end

    # For a list: { application_id => reasons } over the whole company in three groupings, so a page
    # of applicants costs one pass, not one query per row.
    def flags(company_id)
      apps = JobApplication.joins(:job).where(jobs: { client_company_id: company_id }).includes(:candidate, cv_attachment: :blob).to_a
      found = Hash.new { |h, k| h[k] = [] }
      { "same email" => ->(a) { a.candidate&.email.to_s.downcase.strip.presence },
        "same phone number" => ->(a) { (d = digits(a.candidate&.phone)).length >= 8 ? d : nil },
        "same CV file" => ->(a) { a.cv.attached? ? a.cv.blob.checksum : nil } }.each do |reason, key|
        apps.group_by(&key).each { |value, group| group.each { |a| found[a.id] << reason } if value && group.size > 1 }
      end
      found
    end

    # Indonesian numbers written 0812..., +62812... or 62812... are the same number.
    def digits(phone) = phone.to_s.gsub(/\D/, "").sub(/\A62/, "0")
  end
end
