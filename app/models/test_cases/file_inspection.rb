module TestCases
  # Upload safety for a test file (D60, plan §d), judged by CONTENT, never by the name or the
  # browser's content type (both are chosen by the sender). Nothing is ever executed, rendered or
  # extracted: for an Office file only the zip directory and two small XML parts are read.
  #
  # Accepted: .xlsx, .docx, .pdf, .csv, and the detected kind must match the file's extension.
  # Refused, with a reason the uploader can act on:
  #   - legacy binary Office (.xls/.doc: OLE compound file, magic D0 CF 11 E0) and .xlsb;
  #   - macro-enabled OOXML (.xlsm/.docm: content type "macroEnabled", or a vbaProject.bin part);
  #   - ActiveX controls, embedded OLE objects, external workbook links, and external targets of
  #     relationship types that load something on open (attachedTemplate, oleObject, frame,
  #     subDocument); an ordinary hyperlink stays allowed;
  #   - any other zip (an archive), any executable, anything bigger than the cap.
  # Zip bombs: the declared uncompressed sizes are checked before a part is read, and at most
  # MAX_PART_BYTES of a part is ever inflated.
  class FileInspection
    Result = Data.define(:kind, :problems) do
      def ok? = problems.empty?
    end

    PDF_MAGIC = "%PDF-".b
    ZIP_MAGIC = "PK\x03\x04".b
    OLE_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b
    MAX_PART_BYTES = 2.megabytes
    MAX_ENTRIES = 5_000
    RISKY_PARTS = {
      %r{(\A|/)vbaProject\.bin\z}i => "it contains a macro (VBA)",
      %r{(\A|/)activeX/}i => "it contains ActiveX controls",
      %r{(\A|/)embeddings/}i => "it contains embedded objects (OLE)",
      %r{(\A|/)externalLinks/}i => "it contains links to another workbook",
      %r{\Axl/workbook\.bin\z}i => "it is in binary Excel format (.xlsb)"
    }.freeze
    RISKY_REL_TYPES = %w[attachedTemplate oleObject frame subDocument externalLink package].freeze
    PartTooLarge = Class.new(StandardError)
    LABELS = { "xlsx" => "Excel (.xlsx)", "docx" => "Word (.docx)", "pdf" => "PDF", "csv" => "CSV" }.freeze

    def self.call(io:, filename:, allowed: LABELS.keys, max_bytes: TechnicalTestCase::MAX_CASE_FILE_BYTES) =
      new(io:, filename:, allowed:, max_bytes:).call

    def initialize(io:, filename:, allowed:, max_bytes:)
      @io = io
      @filename = filename.to_s
      @allowed = allowed
      @max_bytes = max_bytes
    end

    def call
      size = @io.size
      return refuse("The file is empty. Please choose the file again.") if size.to_i.zero?
      return refuse("The file is larger than #{@max_bytes / 1.megabyte} MB.") if size > @max_bytes

      kind, problem = detect
      return refuse(problem) if problem
      return refuse("File type #{extension_label} is not allowed for this test.") unless @allowed.include?(kind)
      return refuse("The file content is #{LABELS.fetch(kind)}, but its name ends in .#{extension}. Save it again with a matching name.") if extension != kind

      Result.new(kind:, problems: [])
    ensure
      @io.rewind if @io.respond_to?(:rewind)
    end

    private

    def refuse(message) = Result.new(kind: nil, problems: [message])
    def extension = File.extname(@filename).delete_prefix(".").downcase
    def extension_label = extension.empty? ? "without an extension" : ".#{extension}"

    def head
      @head ||= begin
        @io.rewind
        @io.read(8).to_s.b
      end
    end

    def detect
      return ["pdf", nil] if head.start_with?(PDF_MAGIC)
      return [nil, "Legacy Office files (.xls/.doc) are not accepted because they can contain macros. Save it again as .xlsx or .docx."] if head == OLE_MAGIC
      return office_kind if head.start_with?(ZIP_MAGIC)
      return ["csv", nil] if extension == "csv" && plain_text?

      [nil, "File type not recognised. Use .xlsx, .docx, .pdf or .csv."]
    end

    # CSV is the only kind with no magic number: accepted only as UTF-8 text without NUL bytes,
    # which rules out executables and binary files renamed to .csv.
    def plain_text?
      @io.rewind
      sample = @io.read(64.kilobytes).to_s
      sample.force_encoding(Encoding::UTF_8)
      !sample.include?("\0") && (sample.valid_encoding? || sample.byteslice(0, sample.bytesize - 3).to_s.valid_encoding?)
    end

    def office_kind
      require "zip" # lazy: only an upload needs it (keeps already-running processes booting without it)
      @io.rewind
      Zip::File.open_buffer(@io.read) { |zip| return judge_zip(zip) }
    rescue PartTooLarge
      [nil, "The file contains a part that is too large for an ordinary document."]
    rescue Zip::Error, ArgumentError, EOFError
      [nil, "The file is damaged or is not a readable Office document. Please save it again and upload it once more."]
    end

    def judge_zip(zip)
      entries = zip.entries
      return [nil, "The file contains too many parts for a document."] if entries.size > MAX_ENTRIES

      names = entries.map(&:name)
      RISKY_PARTS.each { |pattern, why| return [nil, "The file was refused because #{why}."] if names.any? { |n| n.match?(pattern) } }

      types = read_part(zip, "[Content_Types].xml")
      return [nil, "The file was refused because it contains a macro (.xlsm/.docm format)."] if types.to_s.match?(/macroEnabled|vbaProject/i)
      return [nil, "The file was refused because it loads something external when opened."] if risky_relationship?(zip, entries)

      if names.include?("xl/workbook.xml") then ["xlsx", nil]
      elsif names.include?("word/document.xml") then ["docx", nil]
      else [nil, "Archive files (zip) are not accepted. Upload one .xlsx, .docx, .pdf or .csv document."]
      end
    end

    def risky_relationship?(zip, entries)
      entries.select { |e| e.name.end_with?(".rels") }.any? do |entry|
        xml = read_part(zip, entry.name).to_s
        xml.scan(/<Relationship\b[^>]*>/).any? do |tag|
          external = tag.match?(/TargetMode\s*=\s*["']External["']/i)
          type = tag[/Type\s*=\s*["']([^"']+)["']/, 1].to_s
          external && RISKY_REL_TYPES.any? { |risky| type.end_with?("/#{risky}") }
        end
      end
    end

    def read_part(zip, name)
      entry = zip.find_entry(name)
      return nil if entry.nil?
      raise PartTooLarge if entry.size > MAX_PART_BYTES

      entry.get_input_stream { |stream| stream.read(MAX_PART_BYTES) }
    end
  end
end
