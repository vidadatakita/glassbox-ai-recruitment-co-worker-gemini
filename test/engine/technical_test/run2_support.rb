require_relative "engine07_support"

# Test engine 07, run 2 (2026-10-10 18:1x): fixtures for the slice 1-2 fixes and slices 3-5,
# owned by the engine and independent of test/support/technical_test_factory.rb. Every name,
# address and file content is invented.
module Run2Support
  include Engine07Support

  # A package-3 job through the real brief wizard with the ENGINE's own approved version: answer
  # types xlsx, pdf and csv, rubric weights 60/40, 35 minutes; ad approved, portal open, a named
  # consultant, the gate open unless asked otherwise.
  def r2_job(open_gate: true, types: %w[xlsx pdf csv], weights: [60, 40])
    job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    saved = TestCases::SaveVersion.call(job:, actor: staff_user("consultant"),
                                        params: e7_params(job, weights:, answer_types: types))
    assert saved.ok?, saved.errors.inspect
    assert TestCases::Approve.call(test_case: saved.test_case, actor: staff_user("hr_pic")).ok?
    assert Briefs::Complete.call(job: job.reload, actor: staff_user("hr_pic")).ok?
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id, consultant_id: staff_user("consultant").id)
    open_portal(job)
    Gates::Open.call(stage: job.stages.find_by!(code: "S1")) if open_gate
    job.reload
  end

  def r2_apply(job, name: "Rina Pratiwi")
    @r2_seq = (@r2_seq || 0) + 1
    submit!(job, name:, email: "r2-#{@r2_seq}@uji.example")
  end

  def r2_s1(application) = application.participations.joins(:stage).find_by!(stages: { code: "S1" })
  def r2_s2(application) = application.participations.joins(:stage).find_by!(stages: { code: "S2" })
  def r2_attempt(application) = TestAttempt.find_by(participation: r2_s2(application))

  def r2_answer(application, bytes: e7_xlsx([["Kode", "Koreksi"], ["BRG-07", 3]]), name: "jawaban.xlsx")
    TechnicalTests::Start.call(application:)
    TechnicalTests::SubmitAnswer.call(application:, file: e7_upload(bytes, name))
    r2_attempt(application)
  end

  def r2_reviewer(email: "reviewer-r2@uji.example") = staff_user("reviewer", email:)

  def r2_ratings(attempt, values) = attempt.test_case.criteria.zip(values).to_h { |c, v| [c.id.to_s, v.to_s] }

  def r2_score!(attempt, values, reviewer: r2_reviewer, note: "Catatan penilaian uji.")
    TechnicalTests::ScoreAnswer.call(attempt:, reviewer:, ratings: r2_ratings(attempt, values), note:)
  end

  # S1 decided by a reviewer the way feature 06 would leave it (manual, scored is not needed here).
  def r2_s1_decide!(application, outcome)
    p1 = r2_s1(application)
    Decision.create!(participation: p1, outcome:, basis: "manual", reason_code: "screening_review_confirmed",
                     note: "Keputusan uji", decided_by_id: r2_reviewer.id, decided_at: Time.current,
                     supersedes: p1.current_decision)
  end

  def r2_pdf(body) = "%PDF-1.4\n#{body}\ntrailer<< /Root 1 0 R >>\n%%EOF\n"
end
