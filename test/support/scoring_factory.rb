# Builders for scoring tests. Users arrive in Plan 2; until then actor ids are plain integers.
module ScoringFactory
  ACTOR_ID = 1

  def create_stage(code: "S3", threshold: 65, weight: 20, source: "scorecard", review_below_threshold: false, job: nil)
    job ||= Job.create!(title: "Admin Gudang", golongan: 2, client_company: default_company)
    Stage.create!(job:, code:, score_source: source, threshold:, weight:, review_below_threshold:)
  end

  # D37 (2026-10-10): decisions are refused on a draft stage, so tests that decide open the stage.
  def create_open_stage(**kwargs)
    Stages::Open.call(stage: create_stage(**kwargs))
  end

  def create_participation(stage:, attendance: "attended")
    application = JobApplication.create!(job: stage.job)
    Participation.create!(job_application: application, stage:, attendance:)
  end

  def add_score(participation, value, at: Time.current, supersedes: nil, reason: nil)
    ScoreEntry.create!(participation:, value:, entered_by_id: ACTOR_ID, event_at: at, entered_at: at,
                       supersedes:, correction_reason: reason)
  end

  def decide!(participation, outcome:, basis: "threshold", reason_code: "at_or_above_threshold", note: nil, supersedes: nil)
    Decision.create!(participation:, outcome:, basis:, reason_code:, note:, decided_by_id: ACTOR_ID,
                     decided_at: Time.current, supersedes:)
  end
end
