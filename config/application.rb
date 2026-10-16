require_relative "boot"
require_relative "../lib/glassbox/settings"
require_relative "../lib/glassbox/google_key" # D52: config/storage.yml parses the service-account key at boot

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Glassbox
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Display times in WIB; ActiveRecord keeps storing UTC (blueprint §2.2 rule 8).
    config.time_zone = "Asia/Jakarta"

    # SQL schema dump: schema.rb cannot express the triggers that make score entries and
    # decisions append-only (blueprint §5.1 row 4). With :ruby, db:schema:load would
    # silently drop that guarantee.
    config.active_record.schema_format = :sql

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # lib/glassbox/settings.rb is required at boot (config/initializers/glassbox_settings.rb), so it
    # is kept out of the autoloader, which may not be used from an initializer.
    config.autoload_lib(ignore: %w[assets tasks glassbox])

    # Screen text is Bahasa Indonesia; code, logs and docs stay English (house convention).
    # A3 (16 Oct 2026): the Cup build reads in English. id.yml stays loaded for the screens A4 hides;
    # a locale switch is roadmap, not a feature of this prototype.
    config.i18n.default_locale = :en
    config.i18n.available_locales = %i[en id]
    config.i18n.fallbacks = [:en]

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
