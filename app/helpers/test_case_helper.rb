# Brief step 5 "Technical test" (D60 slice 2). Screen text is English (docs/GLOSSARY-EN.md).
module TestCaseHelper
  # The brief's steps for this job: 1-4 always, 5 only when the package runs S2.
  def brief_steps(job)
    steps = Staff::JobBriefsController::STEP_TITLES.dup
    steps["5"] = JobBriefChange::STEP_LABELS.fetch("5") if job.persisted? && TestCases::Requirement.applies?(job)
    steps
  end

  # periksa=1: the step opens with the empty required fields marked red (JobBriefHelper#missing).
  def brief_step_link(job, number) = number.to_s == "5" ? staff_job_test_case_step_path(job) : staff_job_brief_step_path(job, number, periksa: 1)

  def test_case_state_badge(test_case, current)
    label, tone =
      if test_case.started? then ["In use by applicants", "info"]
      elsif test_case == current then ["Approved, in force", "success"]
      elsif test_case.approved? then ["Approved, replaced by a newer version", "muted"]
      else ["Draft, awaiting HR approval", "warning"]
      end
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end

  def scan_badge(test_case)
    tone = { "clean" => "success", "infected" => "danger", "scan_unavailable" => "warning", "pending_scan" => "info" }
    content_tag(:span, test_case.scan_label, class: "portal-state portal-state--#{tone.fetch(test_case.scan_state.to_s, 'muted')}")
  end

  # A multi-value field renders as its own list, never a comma-joined string (house rule).
  def answer_type_chips(test_case)
    types = Array(test_case.answer_types)
    return content_tag(:p, "None chosen yet.", class: "text-muted mb-0") if types.empty?

    content_tag(:ul, safe_join(types.map { |t| content_tag(:li, TechnicalTestCase::ANSWER_TYPES.fetch(t, t)) }), class: "test-case-chips")
  end

  def wib(time) = time && I18n.l(time.in_time_zone, format: :short_wib)
end
