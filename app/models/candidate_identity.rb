# Who may see a candidate's identity (name, email, phone, CV) on a staff screen. ONE rule for every
# staff surface (D62 h7, GlassBox Team's instruction via GlassBox Team 16:36; test engine 07 F-01, 2026-10-10):
#
#   - DataKita staff (consultant, reviewer, admin) always see it: they contact candidates.
#   - The client's users (HR PIC, owner) see it only once the job's screening decisions are
#     CONFIRMED, i.e. the screening stages are closed: the gate "CV screening and technical test" (S1+S2)
#     on packages 3+, S1 alone on package 2. A job with no screening stage (package 1) has nothing
#     to confirm, so names show. Until then they see "Candidate 07", a number stable per job.
#   - Any other or missing role sees nothing (fail closed).
#
# Why closed and not "decided": an open stage's decisions can still be reversed by a person or a
# threshold change (rule 3, D37); a stage closes only when every candidate is decided (§3.4).
# The view decides nothing itself; it asks CandidateIdentityHelper, which asks this module.
module CandidateIdentity
  STAFF_ROLES = %w[consultant reviewer admin].freeze
  CLIENT_ROLES = %w[hr_pic owner].freeze

  module_function

  def visible_to?(viewer, application)
    role = viewer&.role.to_s
    return true if STAFF_ROLES.include?(role)
    return false unless CLIENT_ROLES.include?(role)

    screening_confirmed?(application.job) || decided_at_gate?(application)
  end

  # AI Builder Cup step 06 (owner's choice 2026-10-11): once the HR PIC has chosen Lanjut or Tidak
  # Lanjut for this candidate at the screening step, the decision was made blind and is final, so
  # this candidate's name shows, without waiting for every other candidate to be decided.
  def decided_at_gate?(application)
    return false unless application&.persisted?

    ProgressionChoice.joins(participation: :stage)
                     .where(participations: { job_application_id: application.id }, stages: { code: "S1" }).exists?
  end

  # The stages whose closing confirms the screening decisions: the gate's members when the job has
  # a gate, else S1. None (package 1) = nothing to wait for.
  def screening_confirmed?(job)
    stages = job.stages.where(code: %w[S1 S2]).to_a
    gated = stages.select(&:gated?)
    relevant = gated.any? ? gated : stages.select { |stage| stage.code == "S1" }
    relevant.all? { |stage| stage.status == "closed" }
  end

  # 1-based position of the application among the job's candidate applications, by arrival (id).
  # Stable: a later application never renumbers an earlier one.
  def number(application)
    JobApplication.where(job_id: application.job_id).where.not(candidate_id: nil).where(id: ..application.id).count
  end

  def label(application) = format("Candidate %02d", number(application))
end
