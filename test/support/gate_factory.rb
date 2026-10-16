# Builders for the gate tests (D60 slice 1). Included explicitly by the test classes that need it.
module GateFactory
  # A job with the gate "Seleksi CV dan Tes Teknis" (S1 + S2) plus S5, built directly: the gate
  # tests are about the scoring core, not the brief wizard (which sets the gate through SyncStages
  # and is tested in test/services/gates/sync_stages_gate_test.rb).
  def gated_job(s1_threshold: 60, s2_threshold: 60)
    job = Job.create!(title: "Team Leader Uji", golongan: 3, client_company: default_company)
    s1 = job.stages.create!(code: "S1", score_source: "ai", weight: 13, threshold: s1_threshold, gate: "screening")
    s2 = job.stages.create!(code: "S2", score_source: "manual_or_import", weight: 25, threshold: s2_threshold, gate: "screening")
    job.stages.create!(code: "S5", score_source: "scorecard", weight: 62, threshold: 70)
    [job, s1, s2]
  end

  # One applicant in both gate stages, as Lamar creates them.
  def gate_applicant(s1, s2)
    application = JobApplication.create!(job: s1.job)
    [Participation.create!(job_application: application, stage: s1, attendance: "attended"),
     Participation.create!(job_application: application, stage: s2, attendance: "pending")]
  end

  def scored_decision!(participation, score, outcome)
    add_score(participation, score)
    decide!(participation, outcome:, reason_code: outcome == "pass" ? "at_or_above_threshold" : "below_threshold")
  end
end
