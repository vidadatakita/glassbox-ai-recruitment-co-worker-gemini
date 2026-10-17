# The one next action on brief step 5 (Vida, 17 Oct 2026: "when it is done, the system must say where
# to submit or click"). Read top-down: the first matching state wins. Each Guide names the action and
# where it is: a link (href/anchor on this page) or the "Complete brief" button (complete: true).
#   tone: "success" when the step is finished, "primary" when the current user acts, "muted" when
#   someone else must act.
class TechnicalTestGuide
  Guide = Data.define(:title, :text, :label, :href, :complete, :tone, :problems) do
    def complete? = complete
  end

  def initialize(job, user, view)
    @job = job
    @user = user
    @v = view
  end

  def guide
    return after_brief if @job.brief_complete?
    return to_complete if test_in_force?

    bank = QuestionBank.latest_for(@job)
    return for_bank(bank) if bank
    return for_case(TechnicalTestCase.latest_for(@job)) if TechnicalTestCase.latest_for(@job)

    Guide.new("Build the technical test", "Add questions to the competency bank (by hand, with AI or from Excel), or upload a case document below.",
              "Go to the question bank", @v.staff_job_test_case_step_path(@job, anchor: "question-bank"), false, "primary", [])
  end

  private

  def editor? = TestCases::Authority.may_edit_bank?(@user, @job)
  def test_in_force? = QuestionBank.current_for(@job).present? || TechnicalTestCase.current_for(@job).present?

  def after_brief
    if @job.ad_text.blank?
      Guide.new("Step 5 is done and the brief is complete", "Next: write the job ad applicants will read.", "Write the job ad",
                @v.staff_job_ad_path(@job), false, "success", [])
    else
      Guide.new("Step 5 is done and the brief is complete", "Next: open the applicant portal on the vacancy page.", "Go to the applicant portal",
                @v.staff_job_path(@job, anchor: "applicant-portal"), false, "success", [])
    end
  end

  def to_complete
    problems = Briefs::BriefCheck.new(@job).problems
    if problems.empty?
      Guide.new("The technical test is approved", "Last step: complete the brief. After that you write the job ad and open the applicant portal.",
                "Complete brief", nil, editor?, "primary", [])
    else
      Guide.new("The technical test is approved; the brief still has gaps", "Fix these, then complete the brief:", nil, nil, false, "warning", problems)
    end
  end

  def for_bank(bank)
    if bank.submitted?
      if TestCases::Authority.may_review_bank?(@user, bank)
        Guide.new("The question bank waits for your approval", "Read the questions, then approve or return it with a reason.",
                  "Go to approve or return", @v.staff_job_test_case_step_path(@job, anchor: "question-bank"), false, "primary", [])
      else
        Guide.new("Waiting for the HR Manager", "The question bank is submitted. The HR Manager approves it or returns it with a reason; you will see the result here.",
                  nil, nil, false, "muted", [])
      end
    elsif TestCases::BankReadiness.problems(bank).empty?
      Guide.new("The question bank is ready", "Submit it so the HR Manager can approve it.", "Go to Submit for approval",
                @v.staff_job_test_case_step_path(@job, anchor: "question-bank"), false, "primary", [])
    else
      Guide.new("Keep building the question bank", TestCases::BankReadiness.problems(bank).first, "Go to the question bank",
                @v.staff_job_test_case_step_path(@job, anchor: "question-bank"), false, "primary", [])
    end
  end

  def for_case(test_case)
    Guide.new("The case document waits for approval", "HR approves version #{test_case.version} of the case document below.",
              "Go to the case document", @v.staff_job_test_case_step_path(@job, anchor: "case-document"), false, "primary", [])
  end
end
