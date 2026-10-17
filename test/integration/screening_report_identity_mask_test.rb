require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# Engine-08 F-01 end to end: a name the model echoed in Posisi Terakhir, a quote, a claim and the
# label reason never reaches a blind hr_admin (list, detail, both xlsx sheets); the superadmin still
# reads the text as stored; the stored row is unchanged.
class ScreeningReportIdentityMaskTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @job, = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
    @a = JobApplication.joins(:candidate).find_by!(job: @job, candidates: { name: "Sample Candidate A" })
    @a.candidate.update_columns(name: "Kartika Gema Putri")
    p1 = @a.participations.joins(:stage).find_by!(stages: { code: "S1" })
    old = ScreeningResult.current_for(p1.id).first
    echoed = "Kartika Gema Putri menyusun jurnal umum dan rekonsiliasi bank bulanan"
    @result = ScreeningResult.create!(old.attributes.except("id").merge(
      "created_at" => Time.current, "last_position" => { "text" => "Kartika Gema Putri, Supervisor Akuntansi", "quote" => echoed, "verified" => false },
      "narratives" => old.narratives.merge("strengths" => [{ "claim" => "Kartika teliti", "quote" => echoed, "verified" => false }]),
      "judgements" => old.judgements.map { |j| j.merge("quote" => echoed) }, "label_reason" => "Kartika cocok"))
  end

  def xlsx_text(body)
    require "zip"
    text = +""
    Zip::File.open_buffer(StringIO.new(body)) { |zip| text << zip.read("xl/sharedStrings.xml") }
    text
  end

  # Three roles (17 Oct 2026): every hr_admin (the HR PIC and the consultant alike) and every
  # hr_manager is blind until the screening decision is confirmed; only the superadmin reads the
  # names, and so the text as stored.
  test "blind hr_admin (HR PIC, consultant): no name anywhere on list, detail or xlsx; the superadmin sees the stored text" do
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_report_path(@job)
      refute_match(/Kartika|Gema Putri/i, response.body, role)
      assert_includes response.body, "[nama], Supervisor Akuntansi", role
      get staff_job_screening_report_candidate_path(@job, @a.id)
      refute_match(/Kartika|Gema Putri/i, response.body, role)
      get staff_job_screening_report_export_path(@job)
      refute_match(/Kartika|Gema Putri/i, xlsx_text(response.body), role)
      sign_out
    end
    sign_in_as staff_user("admin")
    get staff_job_screening_report_candidate_path(@job, @a.id)
    assert_includes response.body, "Kartika Gema Putri, Supervisor Akuntansi", "control: names visible, text as stored"
    assert_equal "Kartika Gema Putri, Supervisor Akuntansi", @result.reload.last_position["text"], "stored row unchanged"
  end

  # The masking rule covers contacts too: a blind hr_admin who read the email or phone could identify
  # the candidate behind "Candidate 01". Control: the superadmin sees the contact. Kept failing on
  # purpose while ScreeningReport::Visibility#contacts? shows contacts to every hr_admin before the
  # gate (reported as a suspected app defect, 17 Oct 2026).
  test "blind hr_admin sees no contact on the candidate page; the superadmin does" do
    email = @a.candidate.email
    assert email.present?, "fixture: the candidate has an email"
    %w[hr_pic consultant].each do |role|
      sign_in_as staff_user(role)
      get staff_job_screening_report_candidate_path(@job, @a.id)
      assert_includes response.body, "Candidate 01", "fixture: #{role} is blind"
      refute_includes response.body, email, "#{role} sees the contact of a masked candidate"
      sign_out
    end
    sign_in_as staff_user("admin")
    get staff_job_screening_report_candidate_path(@job, @a.id)
    assert_includes response.body, email, "control: the superadmin sees the contact"
  end
end
