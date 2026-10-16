# frozen_string_literal: true

require "json"

module Glassbox
  # The Google service-account key (D52) is parsed in ONE place, and nothing it contains may reach
  # a log, a screen or a table (test engine F-10-01, 2026-10-10).
  #
  # Why this exists: the commonest paste mistake is real line breaks inside "private_key". Ruby's
  # JSON::ParserError then quotes the input after the error point, which IS the private key, and
  # that message used to be stored in appointments.calendar_error and the append-only
  # google_integration_events table, and shown on Settings. Here the parse error is
  # replaced by one that names only the line and column.
  #
  # Plain Ruby, required from config/application.rb, because config/storage.yml needs it while the
  # app boots (app/ constants cannot be autoloaded then).
  module GoogleKey
    class Invalid < StandardError; end

    PEM = /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|\z)/m

    module_function

    # Hash, or raises Invalid with a message that holds no part of the input.
    def parse(raw)
      data = JSON.parse(raw.to_s)
      raise Invalid, "service account JSON must be a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      where = e.message[/line \d+ column \d+/]
      # cause: nil, or Ruby prints the original JSON::ParserError (with the key) under "Caused by".
      raise Invalid, "service account JSON is not valid#{" (#{where})" if where}; paste the key file contents again as one line", cause: nil
    end

    # For any text about to be stored or shown: a PEM private key, and anything after an opening
    # PEM marker, is cut out. Defence in depth behind #parse.
    def redact(text)
      text.to_s.gsub(PEM, "[key redacted]")
    end
  end
end
