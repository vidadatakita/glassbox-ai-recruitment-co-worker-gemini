# FLOW v2.1 §9 rule 6: a Gemini model id outside Screening::Config::KNOWN_MODELS stops the boot, never a
# silent fallback. after_initialize so the autoloaded Config is available; the settings registry has
# already checked the key names and the thinking values by then (config/initializers/glassbox_settings.rb).
Rails.application.config.after_initialize do
  Screening::Config.validate_models!(ENV)
end
