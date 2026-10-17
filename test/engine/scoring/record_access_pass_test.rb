require "test_helper"
require_relative "bank_scoring_pass_helper"

# Independent test pass, competency test scoring slice C: who may record the result, on which
# applications, with what input, and how often. The consultant fixture here is an HR MANAGER: an HR
# Admin consultant is already stopped by the role check, so only a manager-consultant shows whether
# the "never the vacancy's consultant" rule exists at all (service and database trigger).
class RecordAccessPassTest < ActionDispatch::IntegrationTest
  include BankScoringPassHelper

  setup do
    setup_bank!
    @other_manager = staff_user("owner") # a second HR Manager of the same company
  end

  def rated_pair!
    strong = pass_applicant!("strong@contoh.example", mc_right: 5)
    weak = pass_applicant!("weak@contoh.example", mc_right: 0)
    pass_ai_rate!(strong, CapturingClient.new({ rating: 5 }))
    pass_ai_rate!(weak, CapturingClient.new({ rating: 1 }))
    [strong, weak].each { |d| pass_s1!(d) }
    [strong.reload, weak.reload]
  end

  def review_params(draft, value = "4", note: "Clear steps, checked against the anchors.")
    { mode: "review", note:, ratings: written_answers(draft).to_h { |a| [a.id, value] } }
  end

  test "an HR Manager who is the vacancy's consultant cannot record or confirm: service, request and database" do
    strong, weak = rated_pair!
    @job.update_columns(consultant_id: @manager.id)
    error = assert_raises(ApplicationDrafts::RecordScore::Refused) do
      ApplicationDrafts::RecordScore.call(draft: weak, reviewer: @manager, mode: "ai")
    end
    assert_match(/consultant/, error.message)
    refused_by_database do
      written_answers(strong).first.update_columns(review_rating: 4, reviewed_by_id: @manager.id, reviewed_at: Time.current)
    end
    ActiveRecord::Base.transaction(requires_new: true) do
      written_answers(strong).first.update_columns(review_rating: 4, reviewed_by_id: @other_manager.id, reviewed_at: Time.current)
      raise ActiveRecord::Rollback
    end # control: another HR Manager passes the same trigger
    sign_in_as @manager
    post staff_job_bank_scoring_record_path(@job, strong), params: review_params(strong)
    assert_response :unprocessable_content
    assert_equal [0, 0], s2_records(strong)
    assert_equal [nil], written_answers(strong).map(&:review_rating).uniq
  end

  test "the refusal page shown to a manager-consultant does not offer the scoring controls" do
    strong, = rated_pair!
    @job.update_columns(consultant_id: @manager.id)
    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    assert_select "select[name^='ratings[']", 0, "control: the board itself hides them from the consultant"
    sign_in_as @manager
    post staff_job_bank_scoring_record_path(@job, strong), params: review_params(strong)
    assert_response :unprocessable_content
    assert_equal [0, 0], s2_records(strong)
    assert_equal [nil], written_answers(strong).map(&:review_rating).uniq
    assert_select "select[name^='ratings[']", 0, "the refusal page must not offer the consultant the scoring controls"
    assert_select "button[name=commit]", 0
  end

  test "an HR Admin reads the board but cannot record; the database refuses an HR Admin as reviewer" do
    _strong, weak = rated_pair!
    admin = staff_user("hr_pic")
    sign_in_as admin
    get staff_job_bank_scorings_path(@job)
    assert_response :success
    assert_select "button[name=commit]", 0, "no record button for an HR Admin"
    post staff_job_bank_scoring_record_path(@job, weak), params: { mode: "ai" }
    assert_redirected_to staff_jobs_path
    assert_equal [0, 0], s2_records(weak)
    refused_by_database do
      written_answers(weak).first.update_columns(review_rating: 2, reviewed_by_id: admin.id, reviewed_at: Time.current)
    end
    refute ApplicationDrafts::RecordScore.call(draft: weak, reviewer: staff_user("admin"), mode: "ai").nil?, "control: the superadmin may record"
    assert_equal [1, 1], s2_records(weak)
  end

  test "a draft id is looked up inside the vacancy in the URL only; a draft not yet sent is never scored" do
    _strong, weak = rated_pair!
    other_job = technical_test_job
    sign_in_as @manager
    get staff_job_bank_scorings_path(other_job)
    assert_response :success
    refute_includes response.body, "/bank-scoring/#{weak.id}/record", "another vacancy's board does not list this applicant"
    post staff_job_bank_scoring_record_path(other_job, weak), params: { mode: "ai" }
    assert_response :not_found
    post staff_job_bank_scoring_retry_path(other_job, weak)
    assert_response :not_found
    Rails.cache.clear
    get apply_start_path(@job.public_code)
    token = Nokogiri::HTML(response.body).at("input[name='lamaran[consent_token]']")["value"]
    post apply_start_path(@job.public_code), params: { lamaran: { name: "Pass unsent", email: "unsent@contoh.example", phone: "081234567891", consent: "1", consent_token: token },
                                                      knockout: @job.knockout_questions.to_h { |q| [q.id.to_s, "ya"] } }
    unsent = ApplicationDraft.where(job_id: @job.id, submitted_at: nil).order(:id).last
    assert unsent
    sign_in_as @manager
    post staff_job_bank_scoring_record_path(@job, unsent), params: { mode: "ai" }
    assert_response :not_found
    assert_equal [0, 0], s2_records(weak)
  end

  test "review ratings outside 1-5, missing, or a blank note are refused and leave nothing written" do
    strong, = rated_pair!
    sign_in_as @manager
    bad = [review_params(strong, "0"), review_params(strong, "6"), review_params(strong, "abc"), review_params(strong, "4.5"),
           review_params(strong, "4", note: "   "), review_params(strong).merge(ratings: {})]
    one_missing = review_params(strong)
    one_missing[:ratings].delete(one_missing[:ratings].keys.first)
    (bad << one_missing).each do |params|
      post staff_job_bank_scoring_record_path(@job, strong), params: params
      assert_response :unprocessable_content, params.inspect
      assert_equal [nil], written_answers(strong).map(&:review_rating).uniq, "no rating survives a refusal: #{params.inspect}"
      assert_equal [0, 0], s2_records(strong)
    end
    post staff_job_bank_scoring_record_path(@job, strong), params: review_params(strong, "3")
    assert_redirected_to staff_job_bank_scorings_path(@job), "control: a complete review records"
    assert_equal [3], written_answers(strong).map(&:review_rating).uniq
  end

  test "ratings sent for another applicant's answers change nothing on that applicant" do
    strong, weak = rated_pair!
    sign_in_as @manager
    params = review_params(strong)
    written_answers(weak).each { |a| params[:ratings][a.id] = "5" }
    post staff_job_bank_scoring_record_path(@job, strong), params: params
    assert_redirected_to staff_job_bank_scorings_path(@job)
    assert written_answers(weak).all? { |a| a.review_rating.nil? && a.reviewed_by_id.nil? }
    assert_equal [0, 0], s2_records(weak)
  end

  test "a result is recorded once: one ScoreEntry and one Decision, whatever mode the second press uses" do
    strong, weak = rated_pair!
    assert ApplicationDrafts::RecordScore.call(draft: weak, reviewer: @manager, mode: "ai")
    assert_equal [1, 1], s2_records(weak)
    %w[ai review].each do |mode|
      assert_raises(ApplicationDrafts::RecordScore::Refused) do
        ApplicationDrafts::RecordScore.call(draft: weak, reviewer: @other_manager, mode:, note: "Again.", ratings: written_answers(weak).to_h { |a| [a.id, 5] })
      end
    end
    assert_equal [1, 1], s2_records(weak)
    assert_equal [nil], written_answers(weak).map(&:review_rating).uniq, "the refused second press wrote no rating"
    assert_raises(ApplicationDrafts::RecordScore::Refused) { ApplicationDrafts::RecordScore.call(draft: strong, reviewer: @manager, mode: "ai") }
    assert_raises(ApplicationDrafts::RecordScore::Refused) { ApplicationDrafts::RecordScore.call(draft: strong, reviewer: @manager, mode: "guess") }
    assert_equal [0, 0], s2_records(strong)
  end

  test "an applicant eliminated at CV screening is not scored" do
    _strong, weak = rated_pair!
    # decisions are append-only: a newer decision replaces the pass as the current one.
    s1 = s1_of(weak.job_application)
    Decision.create!(participation: s1, outcome: "eliminate", basis: "manual", reason_code: "pass_check", supersedes: s1.current_decision,
                     note: "Invented.", decided_by_id: @manager.id, decided_at: Time.current)
    error = assert_raises(ApplicationDrafts::RecordScore::Refused) { ApplicationDrafts::RecordScore.call(draft: weak, reviewer: @manager, mode: "ai") }
    assert_match(/CV screening/, error.message)
    assert_equal [0, 0], s2_records(weak)
  end

  test "the board hides the applicant's name from an HR Manager until screening is confirmed; house rules hold" do
    strong, weak = rated_pair!
    sign_in_as @manager
    get staff_job_bank_scorings_path(@job)
    assert_response :success
    body = response.body
    refute_includes body, "Pass strong@contoh.example"
    refute_includes body, "strong@contoh.example"
    assert_match(/Candidate \d\d/, body)
    doc = Nokogiri::HTML(body)
    assert_equal body.scan(/<form\b/).size, doc.css("form").size, "no form inside a form"
    assert doc.css("form form").empty?
    assert_empty doc.css("button[disabled], input[type=submit][disabled]"), "no submit control is disabled"
    doc.css("button[name]").each { |b| assert b["value"].present?, "named button #{b['name']} carries a value" }
    assert_equal 2, doc.css("form.bank-scoring-form").size

    post staff_job_bank_scoring_record_path(@job, weak), params: { mode: "ai" }
    assert_redirected_to staff_job_bank_scorings_path(@job)
    refute_includes flash[:notice].to_s, "weak@contoh.example", "the notice names the applicant the same blind way"

    sign_in_as staff_user("admin")
    get staff_job_bank_scorings_path(@job)
    assert_includes response.body, "Pass strong@contoh.example", "control: the superadmin sees names"
  end

  test "retry of the AI run: only a failed run, only by an HR Manager who is not the consultant" do
    draft = pass_applicant!("again@contoh.example", mc_right: 2)
    pass_ai_rate!(draft, CapturingClient.new({ rating: 3 }))
    assert_equal "done", draft.reload.ai_status
    sign_in_as @manager
    post staff_job_bank_scoring_retry_path(@job, draft)
    assert_redirected_to staff_job_bank_scorings_path(@job)
    assert_equal "done", draft.reload.ai_status, "a finished run is not reset to pending"

    draft.update_columns(ai_status: "failed", ai_error: "Invented timeout.")
    @job.update_columns(consultant_id: @manager.id)
    post staff_job_bank_scoring_retry_path(@job, draft)
    assert_equal "failed", draft.reload.ai_status, "the consultant cannot retry"
    sign_in_as staff_user("hr_pic")
    post staff_job_bank_scoring_retry_path(@job, draft)
    assert_equal "failed", draft.reload.ai_status, "an HR Admin cannot retry"

    sign_in_as @other_manager
    post staff_job_bank_scoring_retry_path(@job, draft)
    assert_redirected_to staff_job_bank_scorings_path(@job)
    assert_equal "pending", draft.reload.ai_status, "control: another HR Manager retries a failed run"
  end
end
