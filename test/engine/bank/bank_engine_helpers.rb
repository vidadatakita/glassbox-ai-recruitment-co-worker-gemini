# Shared builders for the independent competency-bank suite (slice A, 17 Oct 2026). Every name,
# figure and text is invented. Banks are built through TestCases::SaveBank / BankDecision, the same
# path the screen uses, so a fixture never holds a row the application could not have written.
module BankEngineHelpers
  def bank_setup!
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
    @activity = @job.activities.first
    @competency = @job.competencies.first
  end

  def save_bank(action, params = {}, actor: @admin, job: @job, **kw)
    TestCases::SaveBank.call(job:, actor:, action:, params:, **kw)
  end

  def decide_bank(bank, action, actor:, **kw) = TestCases::BankDecision.call(bank: bank.reload, actor:, action:, **kw)

  def mc_params(section: "technical", prompt: "Invoice total check", job: @job)
    link = section == "technical" ? "a:#{job.activities.first.id}" : "c:#{job.competencies.first.id}"
    { section:, kind: "multiple_choice", link_id: link, prompt:, options: { "0" => "Rp1.500", "1" => "Rp2.500" }, correct: "1" }
  end

  def written_params(section: "role", prompt: "A supplier misses a delivery. What do you do?")
    { section:, kind: "written", link_id: section == "technical" ? "a:#{@activity.id}" : "c:#{@competency.id}",
      prompt:, anchor_1: "blames the supplier", anchor_3: "calls and reschedules", anchor_5: "reschedules and logs a dated fallback" }
  end

  # Exactly the minimum at the default draws (5 / 3): 10 technical and 6 role questions.
  def full_bank!(actor: @admin, job: @job)
    10.times { |i| assert save_bank("add", mc_params(prompt: "Technical #{i}", job:), actor:, job:).ok? }
    6.times { |i| assert save_bank("add", mc_params(section: "role", prompt: "Role #{i}", job:), actor:, job:).ok? }
    QuestionBank.latest_for(job)
  end

  def submitted_bank!
    bank = full_bank!
    assert decide_bank(bank, "submit", actor: @admin).ok?
    bank.reload
  end

  def approved_bank!
    bank = submitted_bank!
    assert decide_bank(bank, "approve", actor: @manager, seen_digest: bank.content_digest).ok?
    bank.reload
  end
end
