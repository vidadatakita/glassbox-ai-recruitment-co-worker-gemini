# Labels for feature 06 (S1 AI screening). Screen text is Bahasa (docs/STANDARD-BAHASA-UI.md).
module ScreeningHelper
  STATE_TONES = { "queued" => "info", "done" => "success", "screening_failed" => "danger", "cv_unreadable" => "warning",
                  "awaiting_release" => "warning", "not_sent" => "muted" }.freeze
  OUTCOME_LABELS = { pass: "Passed", eliminate: "Not passed", review: "Needs review" }.freeze
  CALIBRATION_LABELS = {
    passed: ["Calibrated", "success"], in_progress: ["Not yet calibrated", "warning"],
    failed: ["Not calibrated: the rubric needs work", "danger"], not_applicable: ["Not applicable", "muted"]
  }.freeze

  def screening_state_badge(participation)
    state = participation.screening_state
    return content_tag(:span, "Not screened yet", class: "portal-state portal-state--muted") if state.nil?

    content_tag(:span, Participation::SCREENING_STATES.fetch(state), class: "portal-state portal-state--#{STATE_TONES.fetch(state)}")
  end

  # D13 blind calibration: while a CV is one of the job's calibration CVs and the consultant has not
  # yet judged it, no screen shows the AI's score or outcome for it, so the consultant's judgement is
  # not anchored on the AI. Engine 06 pins this on every staff page (staff_screens_test.rb:51); the
  # AI Builder Cup applicant page (2026-10-11) printed the score, which the 2026-10-12 merge hid.
  # Only the JUDGE is blinded: D13 protects the consultant's own judgement (feature 06 §4.1 step 7).
  # Others do not judge calibration, so they see the score (GlassBox Team, 2026-10-13: HR saw
  # "disembunyikan" on every new job's first CVs). Three roles (17 Oct 2026): the judge is the HR Admin
  # (or superadmin) who is the job's consultant, or any of them while the job has none assigned; the
  # role alone no longer tells the judge apart, so the person is checked.
  def ai_result_blinded?(participation)
    return false unless current_user&.role.in?(%w[hr_admin superadmin])
    return false unless participation&.stage&.code == "S1"

    consultant_id = participation.stage.job.consultant_id
    return false if consultant_id.present? && consultant_id != current_user.id

    calibration = Screening::Calibration.new(participation.stage.job)
    row = calibration.applicable? && calibration.rows.find { |r| r.participation.id == participation.id }
    row.present? && row.judgement.nil?
  end

  def calibration_badge(calibration)
    label, tone = CALIBRATION_LABELS.fetch(calibration.status)
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end

  # Rule 14 / P14: client users see S1 candidates as numbers until the S1 decisions are confirmed;
  # DataKita staff always see names (they must be able to contact candidates). The number is the
  # participation's position in the job's S1 list, so it is stable across screens.
  #
  # Since test engine 07 F-01 (2026-10-10) this delegates to the ONE shared rule,
  # CandidateIdentity / CandidateIdentityHelper#candidate_label: client users see names once the
  # job's screening stages are closed (D62 h7), and the number is per job by arrival. `board` is
  # kept in the signature so existing callers do not change.
  def screening_person(participation, _board = nil)
    candidate_label(participation.job_application)
  end

  def tier_label(tier) = Requirement::TIERS.fetch(tier, tier)

  def judgement_label(tier, judgement)
    return judgement == "met" ? "Met" : "Not met" if tier == "wajib"

    "#{judgement} of 3"
  end

  def outcome_label(outcome) = OUTCOME_LABELS.fetch(outcome.to_sym, outcome.to_s)

  def score_text(value) = number_with_precision(value, precision: 1, separator: ",", delimiter: ".")
end
