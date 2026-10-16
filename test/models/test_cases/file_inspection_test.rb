require "test_helper"

# Plan §d: a test file is judged by its CONTENT. Each refusal has a control: the same shape
# without the dangerous part is accepted.
class TestCases::FileInspectionTest < ActiveSupport::TestCase
  include TestCaseFactory

  def inspect_bytes(bytes, name, **opts) = TestCases::FileInspection.call(io: StringIO.new(bytes.b), filename: name, **opts)

  # An OOXML package built by hand from parts, to plant exactly one dangerous part at a time.
  def ooxml(parts)
    require "zip"
    buffer = Zip::OutputStream.write_buffer do |zip|
      parts.each { |name, body| zip.put_next_entry(name); zip.write(body) }
    end
    buffer.string
  end

  XLSX_TYPES = '<Types><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>'.freeze
  def xlsx_parts = { "[Content_Types].xml" => XLSX_TYPES, "xl/workbook.xml" => "<workbook/>" }

  test "a real xlsx written by caxlsx is accepted as xlsx" do
    result = inspect_bytes(xlsx_bytes, "kasus.xlsx")
    assert result.ok?, result.problems.inspect
    assert_equal "xlsx", result.kind
  end

  test "pdf by magic bytes, csv as UTF-8 text" do
    assert_equal "pdf", inspect_bytes(PortalFactory::PDF_BYTES, "kasus.pdf").kind
    assert_equal "csv", inspect_bytes("kode,qty\nBRG-01,10\n", "kasus.csv").kind
  end

  test "a docx is accepted as docx" do
    docx = ooxml("[Content_Types].xml" => "<Types/>", "word/document.xml" => "<w:document/>")
    assert_equal "docx", inspect_bytes(docx, "kasus.docx").kind
  end

  test "a macro project inside an xlsx is refused, however the file is named" do
    bad = ooxml(xlsx_parts.merge("xl/vbaProject.bin" => "VBA"))
    %w[kasus.xlsx kasus.xlsm].each do |name|
      result = inspect_bytes(bad, name)
      refute result.ok?, name
      assert_match(/macro/, result.problems.first)
    end
    assert inspect_bytes(ooxml(xlsx_parts), "kasus.xlsx").ok?, "control: the same package without vbaProject.bin"
  end

  test "a macro-enabled content type (xlsm renamed to xlsx) is refused" do
    types = XLSX_TYPES.sub("sheet.main+xml", "sheet.macroEnabled.main+xml")
    result = inspect_bytes(ooxml("[Content_Types].xml" => types, "xl/workbook.xml" => "<workbook/>"), "kasus.xlsx")
    assert_match(/macro/, result.problems.first)
  end

  test "ActiveX, embedded OLE objects, external workbook links and xlsb are refused" do
    { "xl/activeX/activeX1.xml" => /ActiveX/, "xl/embeddings/oleObject1.bin" => /OLE/,
      "xl/externalLinks/externalLink1.xml" => /links to another workbook/, "xl/workbook.bin" => /binary/ }.each do |part, why|
      result = inspect_bytes(ooxml(xlsx_parts.merge(part => "x")), "kasus.xlsx")
      refute result.ok?, part
      assert_match why, result.problems.first, part
    end
  end

  test "an external attachedTemplate relationship is refused; an ordinary hyperlink is not" do
    template = '<Relationships><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/attachedTemplate" Target="http://evil.example/t.dotm" TargetMode="External"/></Relationships>'
    link = '<Relationships><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://contoh.example" TargetMode="External"/></Relationships>'
    base = { "[Content_Types].xml" => "<Types/>", "word/document.xml" => "<w:document/>" }
    refute inspect_bytes(ooxml(base.merge("word/_rels/settings.xml.rels" => template)), "kasus.docx").ok?
    assert inspect_bytes(ooxml(base.merge("word/_rels/document.xml.rels" => link)), "kasus.docx").ok?, "control: a hyperlink"
  end

  test "legacy binary Office, a plain archive, an executable renamed to csv, and an empty file are refused" do
    assert_match(/Legacy Office/, inspect_bytes("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1rest", "kasus.xls").problems.first)
    assert_match(/Archive/, inspect_bytes(ooxml("readme.txt" => "hi"), "kasus.xlsx").problems.first)
    refute inspect_bytes("MZ\x90\x00\x03\x00\x00\x00\x04\x00", "kasus.csv").ok?
    assert_match(/empty/, inspect_bytes("", "kasus.csv").problems.first)
  end

  test "the detected kind must match the extension and be allowed" do
    assert_match(/ends in \.pdf/, inspect_bytes(xlsx_bytes, "kasus.pdf").problems.first)
    assert_match(/not allowed/, inspect_bytes(xlsx_bytes, "kasus.xlsx", allowed: %w[pdf]).problems.first)
  end

  test "the size cap is 20 MB for a case file, inclusive" do
    assert_equal 20 * 1024 * 1024, TechnicalTestCase::MAX_CASE_FILE_BYTES
    over = inspect_bytes("a" * 11, "kasus.csv", max_bytes: 10)
    assert_match(/larger than/, over.problems.first)
    assert inspect_bytes("a" * 10, "kasus.csv", max_bytes: 10).ok?, "control: exactly at the cap"
  end

  test "a part whose declared size is too large is refused before it is read (zip bomb)" do
    huge = ooxml(xlsx_parts.merge("[Content_Types].xml" => XLSX_TYPES + (" " * (TestCases::FileInspection::MAX_PART_BYTES + 1))))
    assert_match(/too large/, inspect_bytes(huge, "kasus.xlsx").problems.first)
  end
end
