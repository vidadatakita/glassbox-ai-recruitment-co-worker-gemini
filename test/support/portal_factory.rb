# Builders for portal tests. Every name and address is invented.
module PortalFactory
  PDF_BYTES = "%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".freeze

  def company = default_company

  # Three roles since 17 Oct 2026. The old role names still work here and keep meaning one PERSON each
  # (consultant@ and hr_pic@ are two people, both hr_admin), so a test about "the reviewer is not the
  # vacancy's consultant" still has two people; the role they get is the new one.
  OLD_ROLE = { "hr_pic" => "hr_admin", "consultant" => "hr_admin", "reviewer" => "hr_manager",
               "owner" => "hr_manager", "admin" => "superadmin" }.freeze

  def staff_user(role, email: "#{role}@uji.example")
    new_role = OLD_ROLE.fetch(role.to_s, role.to_s)
    User.find_by(email_address: email) ||
      User.create!(email_address: email, password: "rahasia-uji-123", name: "Uji #{role}", role: new_role,
                   client_company: (new_role == "superadmin" ? nil : company))
  end

  def set_retention(days = 30)
    Portal::UpdateSetting.call(key: "retention_days", value: days.to_s, actor: staff_user("admin"))
  end

  # A COMPLETE consent text (no [PLACEHOLDER]), invented for tests. The real starting text is
  # ConsentTemplate::DRAFT, which D38 forbids the portal to open with.
  COMPLETE_CONSENT = ConsentTemplate::SECTIONS.keys.to_h { |field| [field, "Teks uji untuk bagian #{field}."] }.freeze

  def publish_consent(at: 1.hour.ago)
    ConsentTemplate.in_force || ConsentTemplate.create!(COMPLETE_CONSENT.merge(version: "uji-1", effective_from: at,
                                                                               created_at: Time.current))
  end

  # A job ready for the portal: company, approved ad, two knockout questions, S1 and S5.
  def portal_job(confidential: false, stages: true)
    # brief_status "complete" is set directly, not through Briefs::Complete: these tests are about
    # the portal, and feature 03 refuses an ad approval for a draft brief (approve_ad gate).
    job = Job.create!(title: "Staf Admin Gudang", golongan: 2, client_company: company, location: "Bekasi",
                      confidential:, ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id,
                      brief_status: "complete")
    job.knockout_questions.create!(position: 1, text: "Bersedia bekerja shift?")
    job.knockout_questions.create!(position: 2, text: "Pengalaman minimal 1 tahun?")
    if stages
      job.stages.create!(code: "S1", score_source: "ai", weight: 30, threshold: 60)
      job.stages.create!(code: "S5", score_source: "scorecard", weight: 70, threshold: 70)
    end
    job
  end

  def open_portal(job, closes_at: nil, quota: nil, now: Time.current)
    set_retention unless SystemSetting.retention_days
    publish_consent
    Portal::WindowChange.open!(job:, actor: staff_user("hr_pic"), closes_at:, quota:, now:)
  end

  def pdf_upload(bytes = PDF_BYTES, name: "cv.pdf", type: "application/pdf")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)
  end

  # Runs a statement the database should refuse, inside a savepoint, and returns the error.
  # Without the savepoint the refusal aborts the test transaction, and the NEXT statement fails
  # with InFailedSqlTransaction, a StatementInvalid too, so a second assert_raises would pass
  # without testing anything.
  def refused_by_database
    error = nil
    begin
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    rescue ActiveRecord::StatementInvalid => e
      error = e
    end
    assert error, "expected the database to refuse the statement"
    refute_kind_of PG::InFailedSqlTransaction, error.cause, "the transaction was already aborted; this proves nothing"
    error
  end

  def answers_for(job, value = "ya") = job.knockout_questions.to_h { |q| [q.id.to_s, value] }

  # The fields a candidate types. It carries NO consent token on purpose: a request built from this
  # alone is like a client that never loaded the form, and the server must refuse it (D35). A test
  # that needs a full submission takes the token from the page it was shown (lamar_form_token) or
  # uses submit!, which signs what the page would have shown at that moment.
  def application_params(job, overrides = {})
    { name: "Rina Pratiwi", email: "rina@uji.example", phone: "081234567890", consent: "1",
      knockout: answers_for(job), cv: pdf_upload }.merge(overrides)
  end

  def shown_consent_token
    consent = ConsentTemplate.in_force
    days = SystemSetting.retention_days
    consent && days ? Portal::SubmitApplication.sign_consent(consent, days) : nil
  end

  # Submits through the service and returns [application, raw_token].
  def submit!(job, **overrides)
    params = application_params(job).merge(consent_token: shown_consent_token).merge(overrides)
    result = Portal::SubmitApplication.call(job:, params:)
    raise "submit failed: #{result.errors.inspect}" if result.errors.any?

    [result.application, result.token]
  end
end
