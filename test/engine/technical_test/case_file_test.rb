require "test_helper"
require_relative "engine07_support"

# Test engine, feature 07 slice 2: case-file safety (plan §d). Every hostile file is built here
# from a real caxlsx workbook with rubyzip, so the only difference from an accepted file is the
# part under attack (a control beside each). Then the download: staff only, attachment, nosniff,
# scoped to its job.
class Engine07CaseFileTest < ActionDispatch::IntegrationTest
  include Engine07Support
  include ActiveJob::TestHelper

  XLSX_CT = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

  def inspect_file(bytes, name)
    TestCases::FileInspection.call(io: StringIO.new(bytes.b), filename: name)
  end

  # Rewrites a caxlsx workbook: add parts, replace parts (by name), optionally drop parts.
  def doctored(add: {}, replace: {}, base: e7_xlsx)
    require "zip"
    out = Zip::OutputStream.write_buffer do |zos|
      Zip::File.open_buffer(base) do |zip|
        zip.entries.each do |entry|
          zos.put_next_entry(entry.name)
          zos.write(replace.key?(entry.name) ? replace[entry.name] : entry.get_input_stream.read)
        end
      end
      add.each { |name, data| zos.put_next_entry(name); zos.write(data) }
    end
    out.string
  end

  def content_types(base = e7_xlsx)
    require "zip"
    xml = nil
    Zip::File.open_buffer(base) { |z| xml = z.find_entry("[Content_Types].xml").get_input_stream.read }
    xml
  end

  def refused?(bytes, name) = !inspect_file(bytes, name).ok?

  test "control: a plain caxlsx workbook is accepted as xlsx" do
    result = inspect_file(e7_xlsx, "kasus.xlsx")
    assert result.ok?, result.problems.inspect
    assert_equal "xlsx", result.kind
  end

  test "macro smuggling: vbaProject.bin anywhere, macroEnabled type, renamed .xlsm/.xlsb/.docm" do
    assert refused?(doctored(add: { "xl/vbaProject.bin" => "VBA" }), "kasus.xlsx")
    assert refused?(doctored(add: { "customXml/deep/VBAPROJECT.BIN" => "VBA" }), "kasus.xlsx"), "case-insensitive name"
    ct = content_types.sub("spreadsheetml.sheet.main+xml", "sheet.macroEnabled.main+xml")
    refute_equal content_types, ct, "fixture: the content type was not changed"
    assert refused?(doctored(replace: { "[Content_Types].xml" => ct }), "kasus.xlsx")
    assert refused?(doctored(add: { "xl/vbaProject.bin" => "VBA" }), "kasus.xlsm"), ".xlsm name"
    assert refused?(e7_xlsx, "kasus.xlsm"), "clean content renamed .xlsm is still not an allowed name"
    assert refused?(doctored(add: { "xl/workbook.bin" => "BIN" }), "kasus.xlsx"), "xlsb part"
    docm = doctored(add: { "word/document.xml" => "<w:document/>", "word/vbaProject.bin" => "VBA" })
    assert refused?(docm, "kasus.docx")
  end

  test "legacy OLE (.xls/.doc/.xlsb) renamed .xlsx refused by magic" do
    ole = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b + ("\0" * 504)
    %w[kasus.xlsx kasus.xls kasus.docx kasus.csv].each { |n| assert refused?(ole, n), n }
  end

  test "ActiveX, embedded OLE objects, external workbook links refused; each name variant" do
    { "xl/activeX/activeX1.xml" => "<ax/>", "xl/embeddings/oleObject1.bin" => "OLE",
      "xl/externalLinks/externalLink1.xml" => "<externalLink/>", "word/embeddings/x.docx" => "PK" }.each do |part, data|
      assert refused?(doctored(add: { part => data }), "kasus.xlsx"), part
    end
  end

  test "external relationships that load on open refused; an external hyperlink accepted (control)" do
    rel = lambda do |type|
      %(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) +
        %(<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/#{type}" ) +
        %(Target="http://contoh.invalid/x" TargetMode="External"/></Relationships>)
    end
    %w[oleObject attachedTemplate frame subDocument externalLink].each do |type|
      assert refused?(doctored(add: { "xl/worksheets/_rels/sheet9.xml.rels" => rel.(type) }), "kasus.xlsx"), type
    end
    assert inspect_file(doctored(add: { "xl/worksheets/_rels/sheet9.xml.rels" => rel.("hyperlink") }), "kasus.xlsx").ok?,
           "control: an ordinary external hyperlink"
  end

  test "TargetMode written with single quotes or odd spacing is still caught" do
    rel = %(<Relationships><Relationship Id='r' Type='http://x/relationships/oleObject' Target='http://contoh.invalid' ) +
          %(TargetMode = 'External' /></Relationships>)
    assert refused?(doctored(add: { "xl/_rels/x.rels" => rel }), "kasus.xlsx")
  end

  test "archives: a plain zip, a zip inside a zip named .xlsx, too many parts, an oversized part" do
    require "zip"
    plain = Zip::OutputStream.write_buffer { |z| z.put_next_entry("readme.txt"); z.write("halo") }.string
    assert refused?(plain, "kasus.xlsx")
    assert refused?(plain, "kasus.zip")
    nested = Zip::OutputStream.write_buffer { |z| z.put_next_entry("inner.xlsx"); z.write(e7_xlsx) }.string
    assert refused?(nested, "kasus.xlsx"), "zip in zip"
    many = doctored(add: 5_001.times.to_h { |i| ["xl/media/p#{i}.txt", ""] })
    result = inspect_file(many, "kasus.xlsx")
    refute result.ok?, "a real workbook with 5,001 extra parts"
    assert_match "too many parts", result.problems.join
    assert inspect_file(doctored(add: 100.times.to_h { |i| ["xl/media/p#{i}.txt", ""] }), "kasus.xlsx").ok?, "control: 100 extra parts"
    big_ct = content_types.sub("</Types>", "<!-- #{'A' * (2.megabytes + 10)} --></Types>")
    bomb = doctored(replace: { "[Content_Types].xml" => big_ct })
    assert bomb.bytesize < 1.megabyte, "fixture: the bomb compresses (#{bomb.bytesize} bytes)"
    result = inspect_file(bomb, "kasus.xlsx")
    refute result.ok?, "a 2 MB+ inflating part was read"
    assert_match "too large", result.problems.join
  end

  test "an oversized .rels part (inflates past 2 MB) is refused, not read" do
    big = "<Relationships>#{'<!-- x -->' * 220_000}</Relationships>"
    result = inspect_file(doctored(add: { "xl/_rels/big.rels" => big }), "kasus.xlsx")
    refute result.ok?
  end

  test "extension mismatch: a pdf named .xlsx, an xlsx named .pdf, a docx named .xlsx" do
    pdf = "%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"
    assert refused?(pdf, "kasus.xlsx")
    assert refused?(e7_xlsx, "kasus.pdf")
    docx = doctored(add: { "word/document.xml" => "<w:document/>" }, replace: {}, base: e7_xlsx)
    assert inspect_file(docx, "kasus.xlsx").ok?, "probe: a zip with BOTH workbook.xml and document.xml judged as xlsx"
  end

  test "csv: text accepted, a binary or NUL renamed .csv refused; formula-looking cells accepted (note)" do
    assert inspect_file("kode,qty\nBRG-1,10\n", "kasus.csv").ok?
    assert refused?("MZ\x90\x00\x03\x00".b + ("\0" * 64), "kasus.csv"), "exe renamed csv"
    assert refused?("kode,qty\n\0\0", "kasus.csv")
    assert inspect_file("=cmd|' /C calc'!A0,1\n", "kasus.csv").ok?, "probe: a DDE-style cell passes (content is not parsed)"
  end

  # Plan §d: "magic bytes"; nothing in it reads a PDF's actions. Pinned as observed and reported.
  test "PROBE: a PDF with an /OpenAction JavaScript is accepted (only the magic is checked)" do
    js = "%PDF-1.4\n1 0 obj<< /Type /Catalog /OpenAction << /S /JavaScript /JS (app.alert(1)) >> >>endobj\ntrailer<< /Root 1 0 R >>\n%%EOF\n"
    assert inspect_file(js, "kasus.pdf").ok?, "behaviour changed: the PDF with JavaScript is now refused (update the finding)"
  end

  test "20 MB boundary: exactly 20,971,520 bytes accepted, one byte more refused; DB CHECK at 20,971,521" do
    at = "%PDF-".b + ("\0".b * (20_971_520 - 5))
    assert inspect_file(at, "kasus.pdf").ok?
    refute inspect_file(at + "\0", "kasus.pdf").ok?
    assert_equal "The file is empty. Please choose the file again.", inspect_file("", "kasus.pdf").problems.first
    job = e7_brief
    tc = e7_save(job).test_case
    assert e7_sql_error("UPDATE test_cases SET case_file_bytes = 20971521 WHERE id = #{tc.id}"), "CHECK missing"
    assert_nil e7_sql_error("UPDATE test_cases SET case_file_bytes = 20971520 WHERE id = #{tc.id}")
  end

  test "a refused upload through the service writes nothing: no version, no blob, no audit" do
    job = e7_brief
    before = [TechnicalTestCase.count, ActiveStorage::Blob.count, JobBriefChange.count]
    result = e7_save(job, file: e7_upload(doctored(add: { "xl/vbaProject.bin" => "VBA" }), "kasus.xlsx", XLSX_CT))
    refute result.ok?
    assert_equal before, [TechnicalTestCase.count, ActiveStorage::Blob.count, JobBriefChange.count]
  end

  test "an infected scan refuses the upload and nothing is stored" do
    job = e7_brief
    infected = Class.new { def call(_io) = "infected" }.new
    original = TestCases::FileScan.adapter
    TestCases::FileScan.adapter = infected
    before = [TechnicalTestCase.count, ActiveStorage::Blob.count]
    refute e7_save(job).ok?
    assert_equal before, [TechnicalTestCase.count, ActiveStorage::Blob.count]
  ensure
    TestCases::FileScan.adapter = original
  end

  # ---- download -----------------------------------------------------------------------------
  test "download: every staff role gets an attachment with nosniff and the exact bytes" do
    job = e7_brief
    bytes = e7_xlsx([["Unduh"], [7]])
    tc = e7_save(job, file: e7_upload(bytes, "asli.xlsx")).test_case
    %w[consultant hr_pic owner reviewer admin].each do |role|
      sign_in_as staff_user(role)
      get staff_job_test_case_file_path(job, tc)
      assert_response :success, role
      assert_match(/\Aattachment;/, response.headers["Content-Disposition"], role)
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_equal bytes.b, response.body.b
      assert_equal XLSX_CT, response.media_type
    end
  end

  test "download: no login is sent to sign-in; a candidate status token does not open it" do
    job = e7_brief
    tc = e7_save(job).test_case
    get staff_job_test_case_file_path(job, tc)
    assert_redirected_to new_session_path
    application = JobApplication.create!(job:)
    _link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
    get staff_job_test_case_file_path(job, tc), params: { token: }
    assert_redirected_to new_session_path
  end

  test "download: another job's version id under this job is not found; a swapped attachment is not served" do
    job = e7_brief
    other = e7_brief(package: 3, golongan: 3)
    other_tc = e7_save(other).test_case
    e7_save(job)
    sign_in_as staff_user("consultant")
    get staff_job_test_case_file_path(job, other_tc)
    assert_response :not_found
    # a draft whose recorded blob id no longer matches its attachment: refused, not served
    mine = TechnicalTestCase.latest_for(job)
    mine.update_columns(case_file_blob_id: other_tc.case_file_blob_id)
    get staff_job_test_case_file_path(job, mine)
    assert_response :redirect
    refute_equal other_tc.case_file.download.b, response.body.b
  end

  # A new version copies the previous blob (SaveVersion#copy_from). Replacing the file on that
  # draft must not purge the blob the APPROVED v1 still uses.
  test "shared blob: replacing v2's copied file leaves v1's file downloadable after jobs run" do
    job = e7_brief
    v1 = e7_approved!(job)
    v1_bytes = v1.case_file.download
    v2 = e7_save(job, file: nil, new_version_reason: "Instruksi diperjelas").test_case
    assert_equal v1.case_file_blob_id, v2.reload.case_file.blob.id, "fixture: v2 shares v1's blob"
    perform_enqueued_jobs do
      assert e7_save(job, file: e7_upload(e7_xlsx([["Baru"]]), "baru.xlsx")).ok?
    end
    purges = performed_jobs.count { |j| j[:job] == ActiveStorage::PurgeJob }
    assert_operator purges, :>=, 1, "no PurgeJob ran, so this test could not show the shared blob surviving a purge"
    assert ActiveStorage::Blob.exists?(v1.case_file_blob_id), "v1's blob row was purged"
    sign_in_as staff_user("reviewer")
    get staff_job_test_case_file_path(job, v1)
    assert_response :success
    assert_equal v1_bytes.b, response.body.b
  end
end
