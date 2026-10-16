require "test_helper"

# Answer files that ACT when a staff member opens them are refused on top of the shared inspection
# (engine-07 probe relayed 18:1x): PDF JavaScript/actions/launch/embedded files, CSV cells Excel reads
# as formulas. Controls: a plain PDF and a CSV with a negative number pass.
class TechnicalTests::AnswerContentTest < ActiveSupport::TestCase
  include TechnicalTestFactory

  setup do
    @job = technical_test_job
    params = case_version_params(@job).merge(answer_types: %w[pdf csv], new_version_reason: "Jawaban boleh PDF atau CSV")
    saved = TestCases::SaveVersion.call(job: @job, actor: staff_user("consultant"), params:)
    assert saved.ok?, saved.errors.inspect
    assert TestCases::Approve.call(test_case: saved.test_case, actor: staff_user("hr_pic")).ok?
    @application, = applicant!(@job)
    TechnicalTests::Start.call(application: @application)
  end

  def submit(bytes, name) = TechnicalTests::SubmitAnswer.call(application: @application, file: upload(bytes, name))

  test "a PDF with an OpenAction or JavaScript is refused" do
    ["/OpenAction << /S /JavaScript /JS (app.alert(1)) >>", "/AA << /O 5 0 R >>", "/Launch /F (calc.exe)", "/EmbeddedFile 4 0 R"].each do |body|
      error = assert_raises(TechnicalTests::SubmitAnswer::Refused, body) { submit("%PDF-1.4\n1 0 obj<<#{body}>>endobj\n%%EOF\n", "jawaban.pdf") }
      assert_match "script or an automatic action", error.message
    end
    assert_nil TestAttempt.last.answered_at
  end

  test "control: a plain PDF passes" do
    assert submit(PDF_BYTES, "jawaban.pdf").answered_at
  end

  test "a CSV cell starting with =, +, @ or -text is refused" do
    ["Kode,Koreksi\nBRG-01,=1+1\n", "Kode;Koreksi\nBRG-01;+cmd\n", "a,@SUM(A1)\n", "a,\"-cmd|' /C calc'!A0\"\n"].each do |csv|
      error = assert_raises(TechnicalTests::SubmitAnswer::Refused, csv) { submit(csv, "jawaban.csv") }
      assert_match "formula", error.message
    end
  end

  test "F-08: a formula that starts like a number, after a BOM, full-width, or quoted with spaces is refused" do
    ["a,-2+3+cmd|' /C calc'!A0\n", "\uFEFF=cmd|' /C calc'!A0,1\n", "a,\uFF1D1+1\n", "a,\"  =1+1\"\n", "a,+8x\n", "a,\t=1\n"].each do |csv|
      error = assert_raises(TechnicalTests::SubmitAnswer::Refused, csv.inspect) { submit(csv, "jawaban.csv") }
      assert_match "formula", error.message
    end
  end

  test "control: a CSV with numbers matched whole (-8, -8.5, -1.234,56 with ; separators, +3) and plain text passes" do
    assert submit("Kode;Koreksi;Catatan\nBRG-01;-8;selisih palet\nBRG-02;-8.5;\nBRG-03;-1.234,56;ok\nBRG-04;+3;\n", "jawaban.csv").answered_at
  end
end
