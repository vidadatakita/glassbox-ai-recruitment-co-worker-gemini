module Screening
  # CV text extraction (feature 06; blueprint §1.3 module 3, §4.3 "Unreadable CV"). Uses the
  # pure-Ruby pdf-reader gem; reason in docs/decisions/0003-pdf-text-extraction.md.
  #
  # A PDF with no text layer (a scanned image) gives back no letters. Then the CV is UNREADABLE:
  # state cv_unreadable, "CV tidak terbaca", no API call and no score; a consultant pastes the text
  # or asks for a new CV (§4.3). A broken or encrypted PDF is treated the same way, because what
  # staff can do about it is the same.
  module CvText
    # Fewer letters than this and the "text" is page furniture (page numbers, stray marks), not a
    # CV. Builder default; no number in the spec. Recorded in feature record 06 §2.
    MIN_LETTERS = 40

    module_function

    DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document".freeze

    # "pdf", "docx" or nil, from the file's first bytes (never its name or the browser's type). A
    # zip is called docx only by Portal::SubmitApplication's content inspection; here a zip with a
    # word/document.xml part is read as one.
    def kind(bytes)
      head = bytes.to_s.byteslice(0, 5)
      return "pdf" if head == "%PDF-"

      "docx" if head.start_with?("PK")
    end

    # Returns the extracted text, or nil when the CV is unreadable. PDF or DOCX, told apart by content.
    def extract(bytes)
      return readable_or_nil(docx(bytes)) if kind(bytes) == "docx"

      require "pdf-reader"
      reader = PDF::Reader.new(StringIO.new(bytes))
      text = reader.pages.map(&:text).join("\n")
      readable?(text) ? text : nil
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError
      nil
    end

    def readable?(text) = text.to_s.scan(/[[:alpha:]]/).size >= MIN_LETTERS

    def readable_or_nil(text) = readable?(text) ? text : nil

    # Paragraph text of a .docx (word/document.xml), one paragraph per line, so CV headings stay on
    # their own lines for Screening::EvidenceSections. nil for a zip that is not a Word document.
    def docx(bytes)
      require "zip"
      xml = nil # open_buffer returns the zip, not the block's value
      Zip::File.open_buffer(bytes) { |zip| xml = zip.find_entry("word/document.xml")&.get_input_stream&.read }
      return nil if xml.nil?

      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!
      doc.xpath("//body//p").map { |p| p.xpath(".//t").map(&:text).join }.join("\n")
    rescue Zip::Error, Nokogiri::XML::SyntaxError
      nil
    end
  end
end
