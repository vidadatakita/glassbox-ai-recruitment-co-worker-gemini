module GoogleIntegration
  # One health result for one Google integration (D52): written by `glassbox:google:check`, by a
  # calendar sync, and by a Google login that failed on Google's side. Append-only (database
  # trigger), so "Last failed" cannot be erased by editing the row.
  #
  # The message is cut to 500 characters and never holds a credential: callers pass the exception
  # class and message only, and Google error bodies are cut before they are stored because they
  # can echo the request.
  class Event < ApplicationRecord
    include AppendOnly

    self.table_name = "google_integration_events"

    INTEGRATIONS = %w[login mail storage calendar].freeze

    validates :integration, inclusion: { in: INTEGRATIONS }
    validates :outcome, inclusion: { in: %w[ok failed] }
    validates :source, inclusion: { in: %w[check sync login] }

    def self.record!(integration, source:, error: nil, message: nil)
      create!(integration: integration.to_s, source: source.to_s, outcome: error ? "failed" : "ok",
              error_class: error&.class&.name,
              message: Glassbox::GoogleKey.redact(message || error&.message).truncate(500).presence,
              created_at: Time.current)
    end

    def self.latest(integration) = where(integration: integration.to_s).order(created_at: :desc, id: :desc).first
    def failed? = outcome == "failed"
  end
end
