module InterviewsHelper
  REASONS = {
    "completed" => "Completed", "ended_by_candidate" => "Ended by the candidate", "time_up" => "Ended: time ran out",
    "never_started" => "Never started", "ai_unavailable" => "Ended: the AI was unavailable",
    "consent_withdrawn" => "Stopped: consent withdrawn", "staff_started" => "Screening started by staff"
  }.freeze

  def interviews_status_text(interview)
    interview.open? ? "Open: the candidate has not finished yet." : REASONS.fetch(interview.finish_reason, "Finished")
  end
end
