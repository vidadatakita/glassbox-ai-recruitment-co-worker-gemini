require "test_helper"

# Screen 10 rules: server refusal on a closed window, consent stored with its version and
# retention (D32, D35), knockout by rule (rule 16), PDF check, status link as a digest (D36).
class Portal::SubmitApplicationTest < ActiveSupport::TestCase
  setup { @job = portal_job }

  test "a submission to a window that never opened stores nothing" do
    set_retention
    publish_consent
    assert_no_difference(-> { Candidate.count }) do
      assert_raises(Portal::SubmitApplication::Closed) { submit!(@job) }
    end
    assert_equal 0, JobApplication.count
  end

  test "a submission after HR closed the window stores nothing" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: staff_user("hr_pic"))
    assert_raises(Portal::SubmitApplication::Closed) { submit!(@job) }
    assert_equal 0, Candidate.count
  end

  test "consent is stored with the version shown and the retention days in force" do
    open_portal(@job)
    set_retention(45)
    application, = submit!(@job)
    assert_equal ConsentTemplate.in_force, application.consent_template
    assert_equal 45, application.consent_retention_days
    assert_not_nil application.consent_at
  end

  test "the database refuses a candidate application without consent (D35)" do
    candidate = Candidate.create!(name: "X", email: "x@uji.example", phone: "081200000000")
    error = refused_by_database do
      JobApplication.new(job: @job, candidate:).save!(validate: false)
    end
    assert_match(/job_applications_consent_recorded/, error.message)
  end

  test "no consent box ticked: refused with a message, nothing stored" do
    open_portal(@job)
    result = Portal::SubmitApplication.call(job: @job, params: application_params(@job, consent: "0"))
    assert_includes result.errors, "You need to agree to the use of your data to apply."
    assert_equal 0, JobApplication.count
  end

  test "a file that is not a PDF is refused even when it is named .pdf" do
    open_portal(@job)
    fake = pdf_upload("MZ\x90\x00 not a pdf", name: "cv.pdf")
    result = Portal::SubmitApplication.call(job: @job, params: application_params(@job, cv: fake))
    assert result.errors.any? { |e| e.start_with?("The CV must be a PDF or Word (.docx) file.") }, result.errors.inspect
    assert_equal 0, JobApplication.count
  end

  # A minimal Word document with the given paragraphs.
  def docx_bytes(paragraphs, macro: false)
    require "zip"
    body = paragraphs.map { |t| "<w:p><w:r><w:t>#{t}</w:t></w:r></w:p>" }.join
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("[Content_Types].xml")
      zip.write(%(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>))
      zip.put_next_entry("word/document.xml")
      zip.write(%(<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>#{body}</w:body></w:document>))
      if macro
        zip.put_next_entry("word/vbaProject.bin")
        zip.write("macro")
      end
    end.string
  end

  test "a Word .docx CV is accepted and its text read, heading per line; .doc and a macro .docx are refused" do
    open_portal(@job)
    docx = pdf_upload(docx_bytes(["PENGALAMAN KERJA", "Admin Gudang, PT Maju 2019-2024"]), name: "cv.docx")
    result = Portal::SubmitApplication.call(job: @job, params: application_params(@job, cv: docx, consent_token: shown_consent_token))
    assert_empty result.errors
    assert_equal "PENGALAMAN KERJA\nAdmin Gudang, PT Maju 2019-2024", Screening::CvText.docx(result.application.cv.download)

    legacy = pdf_upload("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1 old word".b, name: "cv.doc")
    refused = Portal::SubmitApplication.call(job: @job, params: application_params(@job, cv: legacy, email: "lain@uji.example", consent_token: shown_consent_token))
    assert_includes refused.errors, "The old Word format (.doc) is not accepted. Save the CV again as .docx or PDF, then upload it again."

    macro = pdf_upload(docx_bytes(["X"], macro: true), name: "cv.docx")
    refused = Portal::SubmitApplication.call(job: @job, params: application_params(@job, cv: macro, email: "lain2@uji.example", consent_token: shown_consent_token))
    assert refused.errors.any? { |e| e.start_with?("The CV must be a PDF or Word (.docx) file.") }, refused.errors.inspect
  end

  test "a CV over 5 MB is refused" do
    open_portal(@job)
    big = pdf_upload(PortalFactory::PDF_BYTES + ("0" * 5.megabytes))
    result = Portal::SubmitApplication.call(job: @job, params: application_params(@job, cv: big))
    assert_includes result.errors, "The CV is larger than 5 MB."
  end

  test "knockout 'tidak' on an OPEN S1 is eliminated at once by rule, reason knockout" do
    open_portal(@job)
    Stages::Open.call(stage: @job.stages.find_by!(code: "S1"))
    answers = answers_for(@job).merge(@job.knockout_questions.first.id.to_s => "tidak")
    application, = submit!(@job, knockout: answers, cv: nil)
    decision = application.participations.first.current_decision
    assert_equal %w[eliminate rule knockout], [decision.outcome, decision.basis, decision.reason_code]
    assert_equal "eliminated", application.status
  end

  test "knockout 'tidak' on a DRAFT S1 is decided by rule when the stage opens (rule 16 with D37)" do
    open_portal(@job)
    answers = answers_for(@job).merge(@job.knockout_questions.first.id.to_s => "tidak")
    application, = submit!(@job, knockout: answers, cv: nil)
    participation = application.participations.first
    assert_nil participation.current_decision, "no decision on a draft stage"
    Stages::Open.call(stage: participation.stage)
    assert_equal "knockout", participation.reload.current_decision.reason_code
  end

  test "the status link is stored only as a digest" do
    open_portal(@job)
    application, token = submit!(@job)
    link = OneTimeLink.find_by!(subject: application)
    assert_equal OneTimeLink.digest(token), link.token_digest
    refute_includes OneTimeLink.pluck(:token_digest), token
    assert_nil link.expires_at, "D36: no N-day expiry"
  end

  test "TENANCY=single: the database refuses a second client company (ONP-1)" do
    company
    error = refused_by_database do
      ClientCompany.create!(name: "PT Kedua", address: "Jl. Dua", city: "Jakarta", contact_email: "hr@dua.example")
    end
    assert_match(/TENANCY=single allows one client company/, error.message)
  end
end
