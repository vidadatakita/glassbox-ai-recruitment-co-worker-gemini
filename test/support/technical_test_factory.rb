# Builders for the D60 slices 3-5 tests (candidate test flow, notices, rubric scoring). Every name,
# address and file content is invented. Included explicitly by the test classes that need it.
module TechnicalTestFactory
  include TestCaseFactory

  # A package-3 job through the real brief wizard: gate S1 + S2, one approved test version (35
  # minutes, xlsx answers, rubric 60/40), the ad approved, the portal open, the gate open unless
  # asked otherwise, and a named consultant.
  def technical_test_job(open_gate: true)
    job = briefed_job(golongan: 3, package: 3)
    job.update!(ad_approved_at: Time.current, ad_approved_by_id: staff_user("hr_pic").id, consultant_id: staff_user("consultant").id)
    open_portal(job)
    Gates::Open.call(stage: job.stages.find_by!(code: "S1")) if open_gate
    job.reload
  end

  # Applies through Portal::SubmitApplication (as Lamar does); returns [application, raw status token].
  def applicant!(job, name: "Dewi Lestari", email: nil, **overrides)
    @applicant_seq = (@applicant_seq || 0) + 1
    submit!(job, name:, email: email || "pelamar#{@applicant_seq}@uji.example", **overrides)
  end

  def s1_of(application) = application.participations.joins(:stage).find_by!(stages: { code: "S1" })
  def s2_of(application) = application.participations.joins(:stage).find_by!(stages: { code: "S2" })

  def answer_file(bytes = xlsx_bytes([["Kode", "Koreksi"], ["BRG-01", 12]]), name = "jawaban.xlsx") = upload(bytes, name)

  # Started and answered through the services, at the given clock.
  def answered!(application, at: Time.current)
    travel_to(at) do
      TechnicalTests::Start.call(application:)
      TechnicalTests::SubmitAnswer.call(application:, file: answer_file)
    end
    TestAttempt.find_by!(participation: s2_of(application))
  end

  def reviewer(email: "reviewer@uji.example") = staff_user("reviewer", email:)

  def ratings_for(attempt, values)
    attempt.test_case.criteria.zip(values).to_h { |criterion, value| [criterion.id.to_s, value.to_s] }
  end
end
