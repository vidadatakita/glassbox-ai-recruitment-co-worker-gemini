module TestCases
  # The antivirus seam for uploaded test files (D60, plan §d). No antivirus runs on the server
  # today, so the default adapter does NOT scan: it records "scan_unavailable", and every screen
  # that offers the file says "Not scanned by antivirus" before the download. A real scanner
  # (ClamAV) is a later adapter with the same one-method contract: call(io) returns one of
  # TechnicalTestCase::SCAN_LABELS' keys. An "infected" result refuses the upload; the version is never
  # approved with it (CHECK test_cases_approved_is_complete).
  module FileScan
    class Unavailable
      def call(_io) = "scan_unavailable"
    end

    mattr_accessor :adapter, default: Unavailable.new

    def self.call(io) = adapter.call(io)
  end
end
