module Portal
  # Changes one screen setting and writes the audit row (ONP-3). Only keys declared in
  # Glassbox::Settings::SCREEN_KEYS can be set; anything else (a secret, an env key) is refused.
  class UpdateSetting
    class Invalid < StandardError; end

    # The actor's company gets its own row; DataKita staff (no company) set the install-wide one.
    def self.call(key:, value:, actor:)
      company_id = Glassbox::Settings.settings_company_id(actor)
      spec = Glassbox::Settings::SCREEN_KEYS[key.to_s]
      raise Invalid, "Unknown setting." if spec.nil?

      normalised = normalise(spec, value)
      SystemSetting.transaction do
        setting = SystemSetting.lock.find_or_initialize_by(key: key.to_s, client_company_id: company_id)
        old = setting.persisted? ? setting.value : nil
        next if old == normalised

        setting.update!(value: normalised)
        SettingChange.create!(key: key.to_s, client_company_id: company_id, old_value: old, new_value: normalised, actor_id: actor.id, created_at: Time.current)
      end
    end

    def self.normalise(spec, value)
      case spec[:type]
      when :integer
        number = Integer(value.to_s.strip, 10)
        raise Invalid, "The minimum value is #{spec[:min]}." if spec[:min] && number < spec[:min]
        raise Invalid, "The maximum value is #{spec[:max]}." if spec[:max] && number > spec[:max]

        number.to_s
      when :boolean then value.to_s == "1" || value.to_s == "true" ? "true" : "false"
      when :list
        chosen = spec[:values] & Array(value).map(&:to_s)
        raise Invalid, "Choose at least one." if chosen.empty?

        chosen.join(",")
      end
    rescue ArgumentError
      raise Invalid, "Enter a whole number."
    end
  end
end
