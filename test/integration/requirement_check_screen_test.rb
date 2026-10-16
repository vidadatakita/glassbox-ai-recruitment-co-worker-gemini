require "test_helper"

# Screening standard, Appendix D structure, on the brief page (video scene 1b): the discrimination
# test flags a requirement that names a protected attribute, the brief cannot be completed while the
# line waits, and the HR owner's decision (keep with a reason / neutral wording / delete) clears it
# under their name. Control: a clean brief completes without anyone running the test by hand.
class RequirementCheckScreenTest < ActionDispatch::IntegrationTest
  include BriefFactory

  FakeClient = Struct.new(:text) do
    def generate(**) = Screening::AiClient::Reply.new(model: "test-model", text:, input_tokens: 1, output_tokens: 1)
  end

  setup do
    @hr = staff_user("hr_pic")
    @job = briefed_job(package: 1, complete: false, test_case: false, ad: false)
    @flagged = @job.requirements.where(tier: "wajib").order(:id).first
    @flagged.update!(text: "Male candidates only", cv_evidence: "Gender on the CV") # names a protected attribute: rule hit
  end

  def problems(job) = Briefs::Complete.call(job: job.reload, actor: @hr).problems.map(&:message)

  test "completing the brief runs the test by itself and stops on the flagged requirement" do
    result = Briefs::Complete.call(job: @job, actor: @hr)
    refute result.ok?
    assert(result.problems.any? { |p| p.message.include?("flagged by the discrimination test") }, result.problems.map(&:message).inspect)
    line = Briefs::RequirementCheck.lines(@job.reload).find { |l| l["id"] == "R#{@flagged.id}" }
    assert_equal %w[replace rule], [line["verdict"], line["source"]]
    assert_nil line["decision"]
  end

  test "the brief page shows the verdicts and the HR owner keeps the line only with a reason" do
    sign_in_as @hr
    post staff_job_requirement_check_path(@job)
    follow_redirect!
    assert_response :success
    assert_select "#requirement-check", /Male candidates only/
    assert_select "#requirement-check .portal-state", text: "Replace"
    assert_select "#requirement-check .portal-state", text: "Rule"
    assert_select "form form", { count: 0 }, "a form inside a form (house hard rule)"
    assert_select "[disabled]", count: 0

    post staff_job_brief_complete_path(@job)
    follow_redirect!
    assert_includes response.body, "flagged by the discrimination test"
    refute @job.reload.brief_complete?

    post staff_job_requirement_check_decision_path(@job, "R#{@flagged.id}"), params: { decision: "keep", note: "" }
    follow_redirect!
    assert_includes response.body, "A reason is required to keep a flagged requirement."
    refute Briefs::RequirementCheck.open_lines(@job.reload).empty?

    post staff_job_requirement_check_decision_path(@job, "R#{@flagged.id}"), params: { decision: "keep", note: "Legal requirement of the client site; documented." }
    follow_redirect!
    assert_includes response.body, "Decision recorded under your name."
    line = Briefs::RequirementCheck.lines(@job.reload).find { |l| l["id"] == "R#{@flagged.id}" }
    assert_equal ["keep", @hr.id, @hr.name], [line["decision"], line["decided_by"], line["decided_by_name"]]
    assert_includes response.body, @hr.name

    post staff_job_brief_complete_path(@job)
    assert @job.reload.brief_complete?, problems(@job).inspect
    assert JobBriefChange.where(job: @job, step: "3").exists?, "run and decision are recorded in the brief history"
  end

  test "neutral wording from the AI replaces the text; a line without wording cannot be replaced; delete removes it" do
    answer = { lines: [{ id: "R#{@flagged.id}", verdict: "replace", reason: "Names gender.", replacement: "Able to lift 20 kg loads during the shift" }] }
    Screening::Config.stub(:enabled?, true) do
      Screening::Config.stub(:client, FakeClient.new(answer.to_json)) { Briefs::RequirementCheck.run!(job: @job, actor: @hr) }
    end
    line = Briefs::RequirementCheck.lines(@job.reload).find { |l| l["id"] == "R#{@flagged.id}" }
    assert_equal "Able to lift 20 kg loads during the shift", line["replacement"], "a rule hit borrows the AI's neutral wording"

    Briefs::RequirementCheck.decide!(job: @job, actor: @hr, line_id: "R#{@flagged.id}", decision: "replace")
    assert_equal "Able to lift 20 kg loads during the shift", @flagged.reload.text
    refute Briefs::RequirementCheck.stale?(@job.reload), "the decision refreshes the digest: the stored test is current"

    other = @job.requirements.where(tier: "sebaiknya").order(:id).first
    other.update!(text: "Women only for the front desk")
    Screening::Config.stub(:enabled?, false) { Briefs::RequirementCheck.run!(job: @job.reload, actor: @hr) }
    error = assert_raises(Briefs::RequirementCheck::Refused) { Briefs::RequirementCheck.decide!(job: @job, actor: @hr, line_id: "R#{other.id}", decision: "replace") }
    assert_match(/no neutral wording/, error.message)
    Briefs::RequirementCheck.decide!(job: @job, actor: @hr, line_id: "R#{other.id}", decision: "delete")
    refute Requirement.exists?(other.id)
  end

  test "control: a clean brief completes without anyone running the test by hand, and the stored result is all keep" do
    clean = briefed_job(package: 1, complete: false, test_case: false, ad: false)
    result = Briefs::Complete.call(job: clean, actor: @hr)
    assert result.ok?, result.problems.map(&:message).inspect
    lines = Briefs::RequirementCheck.lines(clean.reload)
    assert_operator lines.size, :>, 0
    assert lines.all? { |l| l["verdict"] == "keep" }
  end

  test "a reviewer cannot run or decide the test" do
    sign_in_as staff_user("reviewer")
    post staff_job_requirement_check_path(@job)
    assert_redirected_to staff_jobs_path
  end
end
