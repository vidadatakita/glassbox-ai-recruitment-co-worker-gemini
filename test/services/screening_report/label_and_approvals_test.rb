require "test_helper"

# Feature 08 writes: the reviewer's label confirmation (D62 h3/h4), the consultant's narrative
# approval (h2) and the HR PIC's "Rekomendasi User" (h6). Each rule by the service AND by the
# database, each with its control.
class ScreeningReport::LabelAndApprovalsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory
  include ReportFactory

  setup do
    @job = screening_job
    @job.update!(golongan: 2)
    @p = screened_applicant!(@job, name: "Kandidat Uji Satu")
    @result = @p.screening_results.sole
    @reviewer = staff_user("reviewer")
  end

  def confirm(**kw) = ScreeningReport::ConfirmLabel.call(participation: @p, reviewer: @reviewer, **{ label: "pertimbangkan" }.merge(kw))

  def refused(message)
    error = assert_raises(ScreeningReport::ConfirmLabel::Refused) { yield }
    assert_includes error.message, message
  end

  test "the reviewer confirms the AI proposal; a different label needs a note" do
    row = confirm
    assert_equal ["pertimbangkan", @result.id, 2], [row.label, row.screening_result_id, row.job_golongan]
    refused("label differs from the AI advice") { confirm(label: "direkomendasikan") }
    assert_equal "direkomendasikan", confirm(label: "direkomendasikan", note: "Pengalaman stok sangat relevan").label
    assert_equal 2, ScreeningLabelConfirmation.where(participation: @p).count, "append-only: both rows kept"
  end

  test "only a reviewer, never the job's consultant (service and database)" do
    refused("Only a reviewer") { ScreeningReport::ConfirmLabel.call(participation: @p, reviewer: staff_user("hr_pic"), label: "pertimbangkan") }
    @job.update!(consultant: @reviewer)
    refused("consultant of this vacancy") { confirm }
    error = refused_by_database do
      ScreeningLabelConfirmation.create!(participation: @p, screening_result: @result, reviewer: @reviewer,
                                         label: "pertimbangkan", job_golongan: 2, created_at: Time.current)
    end
    assert_includes error.message, "the reviewer is the job's consultant"
  end

  test "over-qualified: only with a last-role Golongan two above the job, a found quote and a note" do
    refused("requires a note") { confirm(label: "over_qualified", last_role_golongan: 4) }
    refused("Grade of the last position is given") { confirm(label: "over_qualified", note: "Posisi terakhir manajer") }
    refused("at least 2 Grades above the vacancy (G2)") { confirm(label: "over_qualified", last_role_golongan: 3, note: "x") }
    row = confirm(label: "over_qualified", last_role_golongan: 4, note: "Posisi terakhir G4 Penyelia")
    assert_equal [4, 2], [row.last_role_golongan, row.job_golongan]
  end

  test "over-qualified is refused when the last-position quote was not found in the CV" do
    p2 = screened_applicant!(@job, name: "Kandidat Uji Dua",
                                   report: report_block(last_position: { text: "Manajer Gudang", quote: "Manajer Gudang Regional" }))
    error = assert_raises(ScreeningReport::ConfirmLabel::Refused) do
      ScreeningReport::ConfirmLabel.call(participation: p2, reviewer: @reviewer, label: "over_qualified", last_role_golongan: 6, note: "x")
    end
    assert_includes error.message, "quote found in the CV"
  end

  # D62 h3 and GlassBox Team's extra rule: never from years of experience. A candidate whose CV shows a long
  # career but whose last role sits AT the job's Golongan cannot be confirmed Over-qualified, and
  # the service has no input through which years could enter.
  test "a long career at the job's own Golongan can never be Over-qualified" do
    refused("at least 2 Grades") { confirm(label: "over_qualified", last_role_golongan: 2, note: "12 tahun pengalaman") }
    refute_includes ScreeningReport::ConfirmLabel.instance_method(:initialize).parameters.map(&:last).map(&:to_s).join(" "), "year"
  end

  test "the database holds the Over-qualified rule and the job Golongan snapshot" do
    attrs = { participation: @p, screening_result: @result, reviewer: @reviewer, label: "over_qualified", created_at: Time.current }
    assert_includes refused_by_database { ScreeningLabelConfirmation.create!(**attrs, job_golongan: 2, last_role_golongan: 3, note: "x") }.message,
                    "label_confirmations_over_qualified_rule"
    assert_includes refused_by_database { ScreeningLabelConfirmation.create!(**attrs, job_golongan: 2, last_role_golongan: 4, note: " ") }.message,
                    "label_confirmations_over_qualified_rule"
    assert_includes refused_by_database { ScreeningLabelConfirmation.create!(**attrs, job_golongan: 1, last_role_golongan: 3, note: "x") }.message,
                    "job_golongan must be the job's Golongan"
    ScreeningLabelConfirmation.create!(**attrs, job_golongan: 2, last_role_golongan: 4, note: "x") # control
    assert_includes refused_by_database { ScreeningLabelConfirmation.update_all(note: "y") }.message, "append-only"
  end

  test "narratives: AI draft until the job's consultant approves; once per result" do
    consultant = @job.consultant
    other = staff_user("consultant", email: "konsultan-lain@uji.example")
    assert_raises(ScreeningReport::ApproveNarratives::Refused) { ScreeningReport::ApproveNarratives.call(result: @result, user: other) }
    assert_raises(ScreeningReport::ApproveNarratives::Refused) { ScreeningReport::ApproveNarratives.call(result: @result, user: staff_user("hr_pic")) }
    ScreeningReport::ApproveNarratives.call(result: @result, user: consultant)
    error = assert_raises(ScreeningReport::ApproveNarratives::Refused) { ScreeningReport::ApproveNarratives.call(result: @result, user: consultant) }
    assert_includes error.message, "already approved"
  end

  test "the database refuses a narrative approval by anyone but the job's consultant" do
    assert_includes refused_by_database {
      ScreeningNarrativeApproval.create!(screening_result: @result, approved_by: staff_user("hr_pic"), created_at: Time.current)
    }.message, "is not a consultant"
    assert_includes refused_by_database {
      ScreeningNarrativeApproval.create!(screening_result: @result, approved_by: staff_user("consultant", email: "k2@uji.example"), created_at: Time.current)
    }.message, "only the job's consultant"
    ScreeningNarrativeApproval.create!(screening_result: @result, approved_by: @job.consultant, created_at: Time.current) # control
  end

  test "Hiring manager's pick: the HR PIC names the manager; nobody else; never a decision" do
    application = @p.job_application
    decisions_before = Decision.count
    row = ScreeningReport::RecordUserRecommendation.call(application:, user: staff_user("hr_pic"), user_name: "Bapak Hendra (Manajer Gudang)", pick: "lanjut")
    assert_equal ["Bapak Hendra (Manajer Gudang)", "lanjut"], [row.user_name, row.pick]
    assert_equal decisions_before, Decision.count, "information only"
    assert_raises(ScreeningReport::RecordUserRecommendation::Refused) do
      ScreeningReport::RecordUserRecommendation.call(application:, user: staff_user("consultant"), user_name: "X", pick: "lanjut")
    end
    assert_raises(ScreeningReport::RecordUserRecommendation::Refused) do
      ScreeningReport::RecordUserRecommendation.call(application:, user: staff_user("hr_pic"), user_name: " ", pick: "lanjut")
    end
    assert_includes refused_by_database {
      UserRecommendation.create!(job_application: application, user_name: "X", pick: "lanjut", entered_by: staff_user("consultant"), created_at: Time.current)
    }.message, "only the HR PIC"
  end
end
