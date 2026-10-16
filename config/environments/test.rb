# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

# Development and test default to the client-side shape (one company). Production has no
# default: the boot check refuses to start without TENANCY (ONP-2, lib/glassbox/settings.rb).
ENV["TENANCY"] ||= "single"
# The suite stubs the Gemini client at the HTTP boundary (ScreeningFactory::FakeGemini); a
# developer's .env must not switch the AI on. GeminiClient.configured? is also true with a service
# account, so GOOGLE_SERVICE_ACCOUNT_JSON is deleted here too: with it set, every unstubbed Vertex
# call in the suite would hit WebMock instead of "AI off". The Google integration tests set it
# themselves with with_env.
ENV["AI_PROVIDER"] = "gemini"
# The suite was written for the release-first rule (D51 B); tests of the automatic mode set "auto".
ENV["AI_SCREENING_REVIEW"] = "required"
%w[AI_API_KEY AI_MODEL AI_THINKING AI_MODEL_HIGH AI_MODEL_MEDIUM AI_MODEL_LOW AI_THINKING_HIGH AI_THINKING_MEDIUM AI_THINKING_LOW GOOGLE_SERVICE_ACCOUNT_JSON].each { |key| ENV.delete(key) }

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  # Memory store, not :null_store: the rate limits on the public Lamar and code pages count in
  # the cache, and with :null_store a rate-limit test could never fail. Request tests clear it.
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
