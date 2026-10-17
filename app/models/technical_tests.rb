# The candidate side of the technical test (D60 slices 3-5; plan Part 1 §b, §d, §e, §a.2).
#
# Clock rules, all on the SERVER's clock (the browser's countdown is display only):
#   - submitted_at  = the application's consent_at (the instant Lamar stored it; created_at for
#                     applications made outside Lamar, which carry no consent time).
#   - start_by      = submitted_at + START_WINDOW (48 hours). A start AT start_by is accepted; one
#                     second later is refused (the database holds the same rule).
#   - due_at        = started_at + the pinned version's time limit (minutes). Refreshing the page or
#                     opening the link on another device never moves it.
#   - an answer is accepted until due_at + GRACE (2 minutes of network slack, recorded per attempt as
#     test_attempts.grace_seconds); one second later it is refused.
#   - not started by start_by, or started and no answer by due_at + grace -> attendance "no_show",
#     and a rule decision "no_show" on S2 (rule 5: never averaged as zero). TechnicalTests::Expire.
module TechnicalTests
  START_WINDOW = 48.hours
  GRACE = 2.minutes
  REMINDER_AFTER = 24.hours
  # Plan §d: 10 MB for the candidate's answer (10,485,760 bytes, inclusive; CHECK
  # test_attempts_answer_max_10_mb). The case file's cap (20 MB) is TechnicalTestCase's.
  MAX_ANSWER_BYTES = 10.megabytes

  module_function

  # The S2 participation of an application when S2 belongs to the gate "Seleksi CV dan Tes
  # Teknis"; nil for every other job (no technical test in the apply flow).
  def participation_for(application)
    application.participations.joins(:stage).find_by(stages: { code: "S2" }).then do |participation|
      participation if participation&.stage&.gated?
    end
  end

  # Who may download a candidate's answer file (B-12 widened 18:4x by the team lead, from the
  # screening-report SPEC §2.4), as of the three roles below. The answer is the candidate's own document and may carry their
  # identity in its metadata. Every surface that offers the download (scoring screen, screening
  # report) asks this one predicate; the signed per-user key is checked separately by the controller.
  def answer_downloadable_by?(user, job)
    # Three roles (17 Oct 2026): the HR Manager scores the test, so always; the superadmin always (team
    # decision: the superadmin can do every step); the HR Admin decides blind, so only once the screening
    # is confirmed. Nobody else.
    case user&.role
    when "hr_manager", "superadmin" then true
    when "hr_admin" then CandidateIdentity.screening_confirmed?(job)
    else false
    end
  end

  # The signed, per-user, short-lived key on every answer-download link (plan §d). Minted only here and
  # checked only here, so the key format lives in one place (scoring screen and screening report).
  ANSWER_KEY_LIFETIME = 5.minutes

  def answer_key(user, attempt)
    Rails.application.message_verifier(:staff_test_answer)
         .generate({ "attempt" => attempt.id, "user" => user.id }, expires_in: ANSWER_KEY_LIFETIME)
  end

  def answer_key_valid?(key, user, attempt)
    data = Rails.application.message_verifier(:staff_test_answer).verified(key.to_s)
    data.is_a?(Hash) && data["attempt"] == attempt.id && data["user"] == user&.id
  end

  def submitted_at(application) = application.consent_at || application.created_at
  def start_by(application) = submitted_at(application) + START_WINDOW
  def answer_deadline(attempt) = attempt.due_at + attempt.grace_seconds.seconds

  # True when the S1 participation of the same application has a CURRENT elimination. Builder
  # decision B-1/B-6: such a candidate is not scored on S2 (gate_eliminated at close), and no
  # no-show decision is written for them, but the candidate side does not hide the test (that
  # would leak an S1 result before the stage closes; see the feature record).
  def s1_eliminated?(application)
    s1 = application.participations.joins(:stage).find_by(stages: { code: "S1" })
    s1&.current_decision&.outcome == "eliminate"
  end
end
