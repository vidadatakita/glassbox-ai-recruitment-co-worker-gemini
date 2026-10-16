require "test_helper"
require Rails.root.join("db/seeds/demo_screening_report").to_s

# Engine-08 F-01 end to end: a name the model echoed in Posisi Terakhir, a quote, a claim and the
# label reason never reaches a blind HR PIC (list, detail, both xlsx sheets); the consultant still
# reads the text as stored; the stored row is unchanged.
class ScreeningReportIdentityMaskTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    set_retention
    publish_consent
    @job, = DemoScreeningReport.run(company:, hr: staff_user("hr_pic"), consultant: staff_user("consultant"), reviewer: staff_user("reviewer"))
    @a = JobApplication.joins(:candidate).find_by!(job: @job, candidates: { name: "Kandidat Contoh A" })
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

  test "blind HR PIC: no name anywhere on list, detail or xlsx; consultant sees the stored text" do
    sign_in_as staff_user("hr_pic")
    get staff_job_screening_report_path(@job)
    refute_match(/Kartika|Gema Putri/i, response.body)
    assert_includes response.body, "[nama], Supervisor Akuntansi"
    get staff_job_screening_report_candidate_path(@job, @a.id)
    refute_match(/Kartika|Gema Putri/i, response.body)
    get staff_job_screening_report_export_path(@job)
    refute_match(/Kartika|Gema Putri/i, xlsx_text(response.body))
    sign_out
    sign_in_as staff_user("consultant")
    get staff_job_screening_report_candidate_path(@job, @a.id)
    assert_includes response.body, "Kartika Gema Putri, Supervisor Akuntansi", "control: names visible, text as stored"
    assert_equal "Kartika Gema Putri, Supervisor Akuntansi", @result.reload.last_position["text"], "stored row unchanged"
  end
end
