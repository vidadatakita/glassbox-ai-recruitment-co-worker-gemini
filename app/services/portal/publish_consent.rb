module Portal
  # Adds a consent text version (D35). Versions are never edited. When a version is already in
  # force, the new one must start in the future, so it is announced on status pages before it
  # applies (Pasal 21(2)). Purpose cannot be empty (also a database check).
  class PublishConsent
    class Invalid < StandardError; end

    def self.call(params:, actor:, now: Time.current)
      effective_from = params[:effective_from].presence && Time.zone.parse(params[:effective_from])
      raise Invalid, "Fill in the effective-from date." if effective_from.nil?
      company_id = Glassbox::Settings.settings_company_id(actor)
      if ConsentTemplate.where(client_company_id: company_id, effective_from: ..now).exists? && effective_from <= now
        raise Invalid, "A new version must take effect in the future so it can be announced first."
      end

      fields = ConsentTemplate::SECTIONS.keys.to_h { |k| [k, params[k].to_s.strip] }
      missing = fields.select { |_k, v| v.empty? }.keys
      raise Invalid, "Required sections: #{missing.map { |k| ConsentTemplate::SECTIONS[k] }.join(', ')}." if missing.any?

      version = "v#{now.in_time_zone.strftime('%Y%m%d-%H%M%S')}"
      ConsentTemplate.create!(fields.merge(version:, effective_from:, client_company_id: company_id, created_by_id: actor.id, created_at: now))
    end
  end
end
