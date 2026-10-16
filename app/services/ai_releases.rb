# D51 B (feature 09): the human release step in front of every AI (Gemini) call, reusable across
# payload kinds. The generic part (who may act, the digest, cuts that only remove, the append-only
# records) lives here; what a release or a decline MEANS for one kind lives in its handler:
#
#   cv_screening          Screening::ReleaseHandler (built)
#   interview_note        no handler: D63 sends interview notes INSIDE a stage_recommendation text,
#                         so nothing of this kind is ever prepared or released
#   stage_recommendation  no handler since the merge of 2026-10-12: feature 11's handler was withheld
#                         with its duplicate D63; the live Progression::Recommend does not use
#                         the release step (open finding for GlassBox Team)
#
# Who may act: a user with the reviewer role who is not the job's consultant. D51 says "a named
# person"; D50, D64 and the feature-06 reviewer rule do not say which role releases, so the builder
# chose the feature-06 reviewer rule (open item for GlassBox Team, feature record 09 §8). HR PIC and owner
# never see the screen: it shows CV text.
module AiReleases
  class Refused < StandardError; end

  HANDLERS = { "cv_screening" => "Screening::ReleaseHandler" }.freeze

  module_function

  def handler_for(release)
    name = HANDLERS[release.payload_kind]
    raise Refused, "This kind of text cannot be sent to the AI yet." if name.nil?

    name.constantize
  end

  # Raises Refused unless `user` may act on `release` (the database checks the same rule).
  def authorize!(release, user)
    raise Refused, "Only a reviewer can check a text before it is sent to the AI." unless user&.role == "reviewer"
    # Read fresh from the database, not from a loaded association: a consultant assigned a moment
    # ago must already be excluded (the database trigger reads it fresh too).
    consultant_id = Job.where(id: release.job_id).pick(:consultant_id)
    raise Refused, "The reviewer cannot be the consultant of this vacancy." if consultant_id.present? && consultant_id == user.id
  end

  # The version must be the newest of its participation and kind, and still undecided.
  def actionable!(release)
    raise Refused, "This text has already been decided." unless release.pending?
    raise Refused, "There is a newer version of this text. Open the latest version." unless release.latest?
  end
end
