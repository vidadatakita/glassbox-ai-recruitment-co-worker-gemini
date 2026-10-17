require "test_helper"

# AI Builder Cup step 07: the HR PIC invites the hiring manager, who scores Interview 2 from a link
# on a phone (no account), blind; the scores, the pick (Rekomendasi User) and the stage decision
# are recorded, the AI recommendation for HR is refreshed, and HR sees the debrief.
class InterviewerScoreTest < ActionDispatch::IntegrationTest
  include TechnicalTestFactory
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    @job = technical_test_job(open_gate: false)
    @application, = applicant!(@job, name: "Dewi Lestari")
    @hr = staff_user("hr_pic")
    Progression::Choose.call(participation: s1_of(@application), actor: @hr, choice: "lanjut", seen_recommendation_id: nil)
    @s3 = @application.participations.joins(:stage).find_by!(stages: { code: "S3" })
  end

  def ratings(value) = @job.competencies.where(stage_code: "S3").to_h { |c| [c.id.to_s, value.to_s] }

  def invite!(name)
    Progression::InviteInterviewer.call(participation: @s3, actor: @hr, name:)
  end

  test "the manager scores from the link, blind; HR sees the debrief once everyone has submitted" do
    _budi, budi_token = invite!("Budi")
    _sari, sari_token = invite!("Sari")

    get interviewer_score_path(budi_token)
    assert_response :success
    assert_includes response.body, CandidateIdentity.label(@application)
    refute_includes response.body, "Dewi", "blind: no candidate name"
    refute_includes response.body, "AI advice", "blind: no AI advice on the assessor's page"
    assert_empty Nokogiri::HTML(response.body).css("button[disabled], [data-disable-with]")

    post interviewer_score_path(budi_token), params: { ratings: ratings(4), pick: "tidak_lanjut", note: "" }
    assert_response :unprocessable_entity
    assert_includes response.body, "A reason is required for a Do not continue pick."

    assert_enqueued_with(job: StageRecommendJob) do
      post interviewer_score_path(budi_token), params: { ratings: ratings(4), pick: "lanjut", note: "Analisa stok rapi." }
    end
    assert_includes response.body, "Thank you, Budi"
    entry = @s3.reload.score_entries.current.last
    assert_equal Scoring::StageScore.from_ratings(ratings(4).values.map(&:to_i)), entry.value
    assert_equal "Analisa stok rapi.", entry.note
    assert_equal ["Budi", "lanjut"], UserRecommendation.last.slice(:user_name, :pick).values
    assert_equal "threshold", @s3.current_decision.basis
    assert_equal "open", @s3.stage.reload.status

    assert_no_difference -> { ScoreEntry.count } do
      post interviewer_score_path(budi_token), params: { ratings: ratings(5), pick: "lanjut" }
    end
    assert_includes response.body, "already been sent", "one submission per link"
  end

  test "HR sees each interviewer's scores only after all have submitted (blind), then the debrief" do
    _budi, budi_token = invite!("Budi")
    _sari, sari_token = invite!("Sari")
    post interviewer_score_path(budi_token), params: { ratings: ratings(4), pick: "lanjut", note: "Rapi." }

    sign_in_as @hr
    get staff_application_path(@application)
    assert_includes response.body, "blind scoring"
    assert_nil Nokogiri::HTML(response.body).at_css("table.debrief-table")

    post interviewer_score_path(sari_token), params: { ratings: ratings(2), pick: "tidak_lanjut", note: "Kurang teliti." }
    get staff_application_path(@application)
    table = Nokogiri::HTML(response.body).at_css("table.debrief-table")
    assert table, "debrief after everyone submitted"
    assert_equal %w[Debrief Budi Sari], table.css("thead th").map(&:text)
    assert_includes table.text, "Kurang teliti."
    expected = Scoring::StageScore.combine([ratings(4), ratings(2)].map { |r| Scoring::StageScore.from_ratings(r.values.map(&:to_i)) })
    assert_equal expected, @s3.reload.current_score, "the stage score is the mean of both interviewers"
  end

  # Every role may create an interviewer's link (17 Oct 2026); signed-out visitors may not.
  test "every role creates the link from the applicant page; a signed-out visitor cannot; a tampered token is refused" do
    sign_in_as @hr
    post staff_participation_interviewer_path(@s3), params: { interviewer_name: "Budi" }
    follow_redirect!
    link = Nokogiri::HTML(response.body).at_css("input[aria-label='Scoring link']")["value"]
    assert_match %r{/score/[\w-]{20,}\z}, link

    %w[reviewer admin].each_with_index do |role, i|
      sign_in_as staff_user(role)
      get staff_application_path(@s3.job_application)
      assert_select "form[action=?]", staff_participation_interviewer_path(@s3), 1, "#{role} sees the link form"
      assert_difference -> { InterviewerInvite.count }, 1, role do
        post staff_participation_interviewer_path(@s3), params: { interviewer_name: "Assessor #{i}" }
      end
      assert_equal staff_user(role).id, InterviewerInvite.order(:id).last.issued_by_id
    end

    sign_out
    assert_no_difference -> { InterviewerInvite.count } do
      post staff_participation_interviewer_path(@s3), params: { interviewer_name: "Anonymous" }
    end

    get interviewer_score_path("tidak-ada")
    assert_response :not_found
  end

  test "the AI receives every interviewer's scorecard, with notes redacted and no names" do
    _i, token = invite!("Budi Santoso")
    post interviewer_score_path(token), params: { ratings: ratings(4), pick: "lanjut", note: "Dewi menjelaskan stok opname dengan jelas." }
    data = Progression::Evidence.call(@s3)[:data]
    card = data[:stages].last[:evidence][:scorecards].first
    assert_equal ["Assessor 1", "user (hiring manager)", "lanjut"], card.values_at(:interviewer, :role, :recommendation)
    sent = data.to_json
    refute_includes sent, "Dewi"
    refute_includes sent, "Budi"
    assert_includes sent, "stok opname"
  end
end
