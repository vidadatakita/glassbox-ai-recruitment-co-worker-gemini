# View side of CandidateIdentity (D62 h7, test engine 07 F-01). Every staff view that prints a
# candidate's name, email, phone or CV link goes through these two methods; do not print
# `candidate.name` directly in a staff view.
module CandidateIdentityHelper
  # Memoised per request: one rule check and one number per application, however often a page asks.
  def candidate_visible?(application)
    @candidate_visibility ||= {}
    # Per application: a candidate decided at the gate shows before the others (decided_at_gate?).
    key = application.id
    @candidate_visibility.fetch(key) { @candidate_visibility[key] = CandidateIdentity.visible_to?(current_user, application) }
  end

  # The name when this viewer may see it, else "Candidate NN" (stable per job).
  def candidate_label(application)
    return application.candidate&.name.presence || "Candidate" if candidate_visible?(application)

    @candidate_numbers ||= {}
    @candidate_numbers[application.id] ||= CandidateIdentity.label(application)
  end
end
