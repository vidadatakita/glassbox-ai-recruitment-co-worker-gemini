module Portal
  # Whether the consent a candidate would see is complete enough to collect applications (D32, D38).
  # Complete means: a retention period is set, a consent text version is in force, and none of its
  # Pasal 21(1) sections still holds a [PLACEHOLDER]. The blocking reasons are listed by name so the
  # admin sees which lines to fill (D38: "the admin sees which lines block it").
  module ConsentReadiness
    module_function

    # company: the job's client company (its own settings, else the install-wide ones).
    def blockers(now = Time.current, company: nil)
      reasons = []
      reasons << "The data retention period has not been set in Settings." if SystemSetting.retention_days(company:).nil?
      consent = ConsentTemplate.in_force(now, company:)
      if consent.nil?
        reasons << "No consent text is available."
      else
        consent.placeholder_sections.each do |heading|
          reasons << %(The consent text section "#{heading}" still contains [PLACEHOLDER].)
        end
      end
      reasons
    end

    def ready?(now = Time.current, company: nil) = blockers(now, company:).empty?
  end
end
