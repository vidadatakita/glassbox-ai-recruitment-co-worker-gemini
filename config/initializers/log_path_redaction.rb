# The candidate status link carries its secret token in the PATH (/status/<token>/...), and Rails'
# parameter filter only filters the query string: the "Started GET ..." log line printed the token
# in plain text, so anyone with log access could open any candidate's status page (found
# 2026-10-10 in log/development.log; docs/perf/2026-10-10-portal-baseline.md §4). This masks the
# token segment wherever Rails asks for the filtered path. If routes move the token elsewhere in
# the path, update TOKEN_PATH and its test (test/lib/log_redaction_test.rb).
module Glassbox
  module FilteredPathRedaction
    TOKEN_PATH = %r{\A(/status/)[^/?]+}

    def filtered_path
      super.sub(TOKEN_PATH, '\1[FILTERED]')
    end
  end
end

ActiveSupport.on_load(:action_dispatch_request) { prepend Glassbox::FilteredPathRedaction }
ActionDispatch::Request.prepend(Glassbox::FilteredPathRedaction) unless ActionDispatch::Request <= Glassbox::FilteredPathRedaction

# Redirects back to a status page ("Redirected to .../status/<token>#penawaran") print the token
# too; Rails replaces a matching redirect location with "[FILTERED]" in the log.
Rails.application.config.filter_redirect << %r{/status/}
