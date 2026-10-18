require "test_helper"
require_relative "engine08_support"

# Engine 08: the Analisa label (D61, D62 h3/h4), the narrative approval (h2) and Rekomendasi User
# (h6), attacked at the service, the controller and raw SQL, with the actor who benefits (rule 19):
# the job's consultant (places the candidate) and the client's HR PIC (picks the candidate).
class Engine08LabelsAndActorsTest < ActionDispatch::IntegrationTest
  include Engine08Support

  setup do
    set_retention
    publish_consent
    @job, @s1, @s2 = e8_job(golongan: 4)
    @ja, @p1, @p2 = e8_applicant(@job, @s1, @s2, name: "Larasati Uji")
    @result = e8_result(@p1, score: 72, label: "pertimbangkan")
    @reviewer = staff_user("reviewer")
    # The consultant has judged the calibration CV, so the report shows the AI result to the people who
    # judge calibration (Screening::CalibrationBlind, 18 Oct 2026); these tests are about labels and actors.
    e8_judge_calibration!(@job)
  end

  def confirm(**kw) = ScreeningReport::ConfirmLabel.call(participation: @p1, reviewer: @reviewer, label: "pertimbangkan", **kw)

  def refused(kind = ScreeningReport::ConfirmLabel::Refused, &)
    before = ScreeningLabelConfirmation.count
    assert_raises(kind, &)
    assert_equal before, ScreeningLabelConfirmation.count, "a refusal wrote a row"
  end

  def sql_refused(sql)
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(sql) } }
  end

  def insert_confirmation(label:, note: "'catatan'", last: "NULL", job_golongan: 4, result: @result, reviewer: @reviewer)
    "INSERT INTO screening_label_confirmations (participation_id, screening_result_id, reviewer_id, label, last_role_golongan, job_golongan, note, created_at) " \
      "VALUES (#{@p1.id}, #{result.id}, #{reviewer.id}, '#{label}', #{last}, #{job_golongan}, #{note}, now())"
  end

  test "the AI can never propose Over-qualified: parser breach, schema enum, and the database CHECK" do
    block = { "last_position" => { "text" => "a", "quote" => "a" }, "education" => { "text" => "b", "quote" => "b" },
              "recent_experience" => { "text" => "c", "quote" => "c" }, "strengths" => [], "blind_spots" => [],
              "tolerance_risks" => [], "credibility_value" => [], "label_proposal" => "over_qualified", "label_reason" => "x" }
    assert Screening::ReportFields.parse(block, extracted: "a b c", redacted: "a b c").breach
    assert Screening::ReportFields.parse(block.merge("label_proposal" => "pertimbangkan"), extracted: "a b c", redacted: "a b c").breach == false, "control"
    refute_includes Screening::AiClient::REPORT_SCHEMA.dig(:properties, :label_proposal, :enum), "over_qualified"
    sql_refused("UPDATE screening_results SET label_proposal = 'over_qualified' WHERE id = #{@result.id}")
    assert_raises(ActiveRecord::StatementInvalid) { e8_result(@p1, score: 50, label: "over_qualified") }
  end

  test "no years or age reaches the label path: service signature, controller params, report schema" do
    params = ScreeningReport::ConfirmLabel.instance_method(:initialize).parameters.map(&:last)
    assert_equal %i[participation reviewer label note last_role_golongan], params
    keys = Screening::AiClient::REPORT_SCHEMA[:properties].keys.map(&:to_s)
    keys.each { |k| refute_match(/year|tahun|age|usia|umur|lahir|birth/i, k) }
    sign_in_as @reviewer
    post staff_job_screening_report_label_path(@job, @ja.id),
         params: { label: "over_qualified", note: "lama berkarier", years_experience: "25", age: "52", last_role_golongan: "" }
    assert_equal 0, ScreeningLabelConfirmation.count, "years/age with no Golongan produced an Over-qualified"
  end

  test "Over-qualified: note, Golongan gap >= 2 and a FOUND last-position quote are each required (service)" do
    refused { confirm(label: "over_qualified", last_role_golongan: 6) }
    refused { confirm(label: "over_qualified", note: "naik dua golongan") }
    refused { confirm(label: "over_qualified", last_role_golongan: 5, note: "gap satu") }
    refused { confirm(label: "over_qualified", last_role_golongan: "6abc", note: "golongan sampah") }
    unverified = e8_result(@p1, score: 72, last_position: e8_fact("Manajer Keuangan", quote: "tidak ada di CV", verified: false))
    refused { confirm(label: "over_qualified", last_role_golongan: 6, note: "kutipan tidak ditemukan") }
    e8_result(@p1, score: 72, last_position: e8_fact("Manajer Keuangan"))
    row = confirm(label: "over_qualified", last_role_golongan: 6, note: "Manajer G6 vs lowongan G4")
    assert_equal [6, 4], [row.last_role_golongan, row.job_golongan]
    refute_equal unverified.id, row.screening_result_id, "confirmed against the CURRENT result"
    assert_equal 0, Decision.where(participation_id: @p1.id).count, "a label writes no Decision (h4)"
  end

  test "a confirmation belongs to the result it confirmed: a re-screen shows the new AI proposal as unconfirmed" do
    confirm(label: "direkomendasikan", note: "bukti kuat")
    row = e8_board(@job, staff_user("consultant")).rows.first
    assert_equal ["direkomendasikan", true], [row.label_key, row.label_confirmed], "control"
    e8_result(@p1, score: 40, label: "tidak_relevan")
    row = e8_board(@job, staff_user("consultant")).rows.first
    assert_equal ["tidak_relevan", false], [row.label_key, row.label_confirmed], "a stale confirmation still counts"
  end

  test "a label different from the AI proposal needs a note; the same label does not" do
    refused { confirm(label: "direkomendasikan") }
    refused { confirm(label: "direkomendasikan", note: "   ") }
    assert confirm(label: "direkomendasikan", note: "bukti kuat").persisted?
    assert confirm(label: "pertimbangkan").persisted?
  end

  # Three roles (17 Oct 2026): the hr_manager (reviewer, owner) and the superadmin confirm; the
  # hr_admin (consultant, HR PIC) is refused; the per-person rule (never the job's consultant) binds all.
  test "who confirms: hr_manager or superadmin only; never the job's consultant, even an hr_manager assigned as the job's consultant (service + trigger)" do
    %w[consultant hr_pic].each do |role|
      refused { ScreeningReport::ConfirmLabel.call(participation: @p1, reviewer: staff_user(role), label: "pertimbangkan") }
    end
    @job.update!(consultant: @reviewer)
    refused { confirm }
    sql_refused(insert_confirmation(label: "pertimbangkan"))
    sql_refused(insert_confirmation(label: "pertimbangkan", reviewer: staff_user("consultant")))
  end

  test "raw SQL: Over-qualified gap 1, no note, forged job Golongan, Golongan 9 all refused; a valid row accepted (control)" do
    sql_refused(insert_confirmation(label: "over_qualified", last: 5))
    sql_refused(insert_confirmation(label: "over_qualified", last: 6, note: "NULL"))
    sql_refused(insert_confirmation(label: "over_qualified", last: 6, note: "'  '"))
    sql_refused(insert_confirmation(label: "over_qualified", last: 5, job_golongan: 3))
    sql_refused(insert_confirmation(label: "pertimbangkan", last: 9))
    other_job, o1, o2 = e8_job(title: "Lain E8")
    _a, x1, _x2 = e8_applicant(other_job, o1, o2, name: "Lain Uji")
    sql_refused(insert_confirmation(label: "pertimbangkan", result: e8_result(x1, score: 50)))
    assert_difference("ScreeningLabelConfirmation.count") { ActiveRecord::Base.connection.execute(insert_confirmation(label: "over_qualified", last: 6)) }
  end

  # D62 h3: "quote-backed". The service checks last_position["verified"]; the record says each rule
  # is "also held by the database where it can be", and this one can (jsonb on the referenced row).
  test "FINDING probe: raw SQL refuses Over-qualified when the current last-position quote was NOT found in the CV" do
    bad = e8_result(@p1, score: 72, last_position: e8_fact("Manajer Keuangan", quote: "karangan", verified: false))
    sql_refused(insert_confirmation(label: "over_qualified", last: 6, result: bad))
  end

  test "controller: reviewer's refused Over-qualified writes nothing and says why; the hr_admin (consultant, HR PIC) cannot post a label" do
    sign_in_as @reviewer
    post staff_job_screening_report_label_path(@job, @ja.id), params: { label: "over_qualified", last_role_golongan: "5", note: "x" }
    assert_redirected_to staff_job_screening_report_candidate_path(@job, @ja.id, anchor: "label-analisa")
    assert_match(/at least 2 Grades/, flash[:alert])
    sign_out
    %w[consultant hr_pic].each do |role|
      sign_in_as staff_user(role)
      post staff_job_screening_report_label_path(@job, @ja.id), params: { label: "pertimbangkan" }
      sign_out
    end
    assert_equal 0, ScreeningLabelConfirmation.count
  end

  test "label colour always travels with the word (helper and every label), Over-qualified amber" do
    view = ActionView::Base.empty.extend(ScreeningReportHelper)
    ScreeningReport::Labels::ALL.each do |key, (word, tone)|
      assert_includes %w[success warning danger], tone
      row = Struct.new(:label_key, :label_confirmed).new(key, false)
      html = Nokogiri::HTML.fragment(view.report_label_badge(row))
      badge = html.at("span.portal-state--#{tone}")
      assert_equal word, badge&.text, "#{key}: colour without the word"
    end
    assert_equal "warning", ScreeningReport::Labels.tone("over_qualified")
    assert_equal "success", ScreeningReport::Labels.tone("direkomendasikan")
    assert_equal "danger", ScreeningReport::Labels.tone("tidak_relevan")
  end

  test "append-only: UPDATE, DELETE and TRUNCATE refused on the three new tables" do
    confirm
    ScreeningReport::ApproveNarratives.call(result: @result, user: @job.consultant)
    ScreeningReport::RecordUserRecommendation.call(application: @ja, user: staff_user("hr_pic"), user_name: "Pak Uji", pick: "lanjut")
    %w[screening_label_confirmations screening_narrative_approvals user_recommendations].each do |t|
      sql_refused("UPDATE #{t} SET created_at = now()")
      sql_refused("DELETE FROM #{t}")
      sql_refused("TRUNCATE #{t}")
    end
  end

  test "narratives: 'AI draft' until the job's consultant approves; other consultant, reviewer, HR PIC refused (service + trigger); once per result; a re-screen drafts again" do
    approve = ->(user, result = @result) { ScreeningReport::ApproveNarratives.call(result:, user:) }
    other = staff_user("consultant", email: "konsultan.lain.e8@uji.example")
    [other, @reviewer, staff_user("hr_pic"), staff_user("owner")].each do |u|
      assert_raises(ScreeningReport::ApproveNarratives::Refused) { approve.(u) }
    end
    sql_refused("INSERT INTO screening_narrative_approvals (screening_result_id, approved_by_id, created_at) VALUES (#{@result.id}, #{other.id}, now())")
    sql_refused("INSERT INTO screening_narrative_approvals (screening_result_id, approved_by_id, created_at) VALUES (#{@result.id}, #{@reviewer.id}, now())")
    sign_in_as @job.consultant
    get staff_job_screening_report_candidate_path(@job, @ja.id)
    assert_select "#narasi .portal-state--warning", text: "AI draft"
    post staff_job_screening_report_narratives_path(@job, @ja.id)
    get staff_job_screening_report_candidate_path(@job, @ja.id)
    assert_select "#narasi .portal-state--warning", count: 0
    assert_select "#narasi .portal-state--success", text: "Approved by the consultant"
    assert_raises(ScreeningReport::ApproveNarratives::Refused) { approve.(@job.consultant) }
    sql_refused("INSERT INTO screening_narrative_approvals (screening_result_id, approved_by_id, created_at) VALUES (#{@result.id}, #{@job.consultant.id}, now())")
    newer = e8_result(@p1, score: 74)
    assert_raises(ScreeningReport::ApproveNarratives::Refused) { approve.(@job.consultant) } # stale result
    get staff_job_screening_report_candidate_path(@job, @ja.id)
    assert_select "#narasi .portal-state--warning", text: "AI draft"
    assert approve.(@job.consultant, newer).persisted?
    _x, q1, _q2 = e8_applicant(@job, @s1, @s2, name: "Stale Uji")
    stale = e8_result(q1, score: 61)
    e8_result(q1, score: 62)
    assert_raises(ScreeningReport::ApproveNarratives::Refused) { approve.(@job.consultant, stale) } # never approved, but not current
  end

  test "narratives: every claim shows its quote; an unfound quote is marked; a quote-less claim says so" do
    e8_result(@p1, score: 72, narratives: e8_narratives(strengths: [e8_claim("Klaim ditemukan", quote: "Menyusun jurnal umum"),
                                                                     e8_claim("Klaim karangan", quote: "tidak ada di CV", verified: false),
                                                                     e8_claim("Klaim kosong", quote: "", verified: false)]))
    sign_in_as @job.consultant
    get staff_job_screening_report_candidate_path(@job, @ja.id)
    items = css_select("#narasi ul.report-claims li")
    found = items.find { it.text.include?("Klaim ditemukan") }
    invented = items.find { it.text.include?("Klaim karangan") }
    empty = items.find { it.text.include?("Klaim kosong") }
    assert_equal "Menyusun jurnal umum", found.at("q").text
    assert_nil found.at(".portal-state--danger"), "control: a found quote is not marked"
    assert_equal "unverified", invented.at(".portal-state--danger")&.text
    assert_includes empty.text, "No quote"
  end

  test "parser: a fact or claim quote that is not in the CV is stored verified=false, never dropped" do
    cv = "PENGALAMAN\nSupervisor Akuntansi di PT Uji\nMenyusun jurnal umum"
    block = { "last_position" => { "text" => "SPV", "quote" => "Supervisor Akuntansi di PT Uji" },
              "education" => { "text" => "S1", "quote" => "S1 Teknik Nuklir" },
              "recent_experience" => { "text" => "x", "quote" => "Menyusun jurnal umum" },
              "strengths" => [{ "claim" => "Teliti", "quote" => "tidak ada" }], "blind_spots" => [], "tolerance_risks" => [],
              "credibility_value" => [], "label_proposal" => "pertimbangkan", "label_reason" => "x" }
    attrs = Screening::ReportFields.parse(block, extracted: cv, redacted: cv).attributes
    assert attrs[:last_position]["verified"]
    refute attrs[:education]["verified"]
    assert_equal [false], attrs[:narratives]["strengths"].map { it["verified"] }
  end

  # Three roles: the hiring manager's pick belongs to the hr_admin (and the superadmin); the
  # hr_manager (owner, reviewer) is refused at the service, the trigger and the controller.
  test "Hiring manager's pick: HR PIC records for a blind 'Candidate NN' (h6 allows it) and it writes no Decision; hr_manager refused (service, trigger, controller)" do
    hr = staff_user("hr_pic")
    assert ScreeningReport::Visibility.new(@job, hr).blind?, "fixture: the HR PIC cannot see the name yet"
    decisions = Decision.count
    rec = ScreeningReport::RecordUserRecommendation.call(application: @ja, user: hr, user_name: "Bu Manajer", pick: "lanjut")
    assert rec.persisted?
    assert_equal decisions, Decision.count, "a recommendation moved a candidate"
    %w[owner reviewer].each do |role|
      assert_raises(ScreeningReport::RecordUserRecommendation::Refused) do
        ScreeningReport::RecordUserRecommendation.call(application: @ja, user: staff_user(role), user_name: "X", pick: "lanjut")
      end
      sql_refused("INSERT INTO user_recommendations (job_application_id, user_name, pick, entered_by_id, created_at) VALUES (#{@ja.id}, 'X', 'lanjut', #{staff_user(role).id}, now())")
    end
    assert_raises(ScreeningReport::RecordUserRecommendation::Refused) { ScreeningReport::RecordUserRecommendation.call(application: @ja, user: hr, user_name: " ", pick: "lanjut") }
    assert_raises(ScreeningReport::RecordUserRecommendation::Refused) { ScreeningReport::RecordUserRecommendation.call(application: @ja, user: hr, user_name: "X", pick: "pass") }
    sign_in_as staff_user("owner")
    post staff_job_screening_report_user_recommendation_path(@job, @ja.id), params: { user_name: "Owner Sendiri", pick: "lanjut" }
    assert_equal 1, UserRecommendation.count, "the owner posted a recommendation"
  end
end
