module Screening
  # Failure kinds of one screening attempt (blueprint §4.3). The kind decides the retry policy in
  # ScreenParticipationJob; the detail is what staff see next to "Screening gagal". Neither ever
  # holds CV text or personal data.
  module Errors
    class Base < StandardError
      attr_reader :kind, :detail

      def initialize(kind, detail)
        @kind = kind
        @detail = detail
        super("#{kind}: #{detail}")
      end
    end

    # Timeout, connection failure, 429, 5xx: 3 retries with increasing wait, then failed.
    class Transient < Base; end
    # The model's answer does not fit the schema, misses a requirement, or was cut off: 1 retry.
    class Malformed < Base; end
    # A refusal after the fallback, or a request the API rejects (400/401/403/404/422): no retry.
    class Permanent < Base; end
    # No API key. Never raised inside a job run (the job checks first); guards direct use.
    class NotConfigured < StandardError; end
    # D51 B (feature 09): the text about to be sent is not byte-identical to the released text.
    # Nothing is sent; Screening::ReleaseGate re-queues the CV for a new release.
    class ReleaseMismatch < Base; end
    # D51 B: a call with text other than the invented sample, outside the release step. A
    # programming error, never a candidate's state: it must surface, not be retried.
    class Unreleased < StandardError; end
  end
end
