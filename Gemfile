source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.4"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# S1 AI screening (feature 06, D50): Gemini on Vertex AI is called over plain REST
# (Screening::GeminiClient, no SDK), so the only gem here is the pure-Ruby PDF text extractor
# (reason: docs/decisions/0003-pdf-text-extraction.md).
gem "pdf-reader", "~> 2.16"

# Feature 07 (D60 slice 2, plan §d): read only the zip DIRECTORY of an uploaded .xlsx/.docx case
# file to refuse macros (vbaProject.bin), ActiveX, embedded OLE objects and external links, without
# extracting or executing anything. Already in the lock through selenium-webdriver (test group);
# declared because application code now requires it in every environment. Plain Ruby, no native code.
gem "rubyzip", "~> 3.7"
# Feature 07 seeds: writes the invented demo case workbooks in pure Ruby (no macros, no Excel
# needed). Also the library D62 h8 names for the screening-report export. Why not hand-written XML:
# a hand-rolled OOXML package is easy to get subtly wrong and then fails to open in Excel.
gem "caxlsx", "~> 4.4"

# D52 Google integrations (docs/decisions/0006-google-integrations.md). Each one is OFF until
# Agung sets its credentials. Staff "Masuk dengan Google": OmniAuth with the Google strategy, and
# the CSRF guard that makes the request phase POST-only with a Rails authenticity token.
gem "omniauth-google-oauth2", "~> 1.2"
gem "omniauth-rails_csrf_protection", "~> 2.0"
# Files in Google Cloud Storage (Active Storage service "google"). require: false because Active
# Storage requires it only when the google service is selected.
gem "google-cloud-storage", "~> 1.62", require: false
# Google Calendar invites for appointments (service account + domain-wide delegation).
gem "google-apis-calendar_v3", "~> 0.57", require: false
gem "googleauth", "~> 1.17", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Reads .env when the app runs with plain `bin/rails server` (Docker Compose passes it already;
  # dotenv never overrides a variable that is set).
  gem "dotenv"
end

group :test do
  # Minitest 6 moved Minitest::Mock / #stub out of minitest into this gem; the stage-service
  # tests stub Decision.create! to prove a failed threshold change rolls back (blueprint §4.3).
  gem "minitest-mock"
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # D52: every Google HTTP call in the tests is stubbed; WebMock also refuses any real call.
  gem "webmock", "~> 3.26"
end
