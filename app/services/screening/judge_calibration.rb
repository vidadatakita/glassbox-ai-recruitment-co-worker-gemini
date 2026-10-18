module Screening
  # The consultant's own judgement of one calibration CV (blueprint §4.1 step 7, D13). Blind: the
  # calibration screen hides the AI's answer for a CV until the consultant has judged it, so the
  # consultant is not anchored by it (the agreement figure would otherwise measure copying).
  #
  # Who: an HR Admin; when the job names its consultant, that consultant. The superadmin always.
  class JudgeCalibration
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(participation:, user:, outcome:, note: nil, now: Time.current)
      @participation = participation
      @user = user
      @outcome = outcome.to_s
      @note = note.to_s.strip.presence
      @now = now
      @job = participation.stage.job
    end

    def call
      refuse!("Only the HR Admin judges calibration CVs.") unless @user.role.in?(%w[hr_admin superadmin])
      # The superadmin may judge too, also on a vacancy with its own consultant (Vida, 18 Oct 2026: "the
      # superadmin passes every check"); ScreeningHelper#ai_result_blinded? hides the AI's answer from
      # the superadmin until it has judged, so the blind-judging rule (D13) still holds.
      if @job.consultant_id.present? && @job.consultant_id != @user.id && @user.role != "superadmin"
        refuse!("Calibration CVs are judged by the consultant of this vacancy (or the superadmin).")
      end
      refuse!("Choose Passed or Not passed.") unless CalibrationJudgement::OUTCOMES.key?(@outcome)

      calibration = Calibration.new(@job)
      refuse!("This CV is not one of the 20 calibration CVs.") unless calibration.member?(@participation)
      if CalibrationJudgement.exists?(participation: @participation, rubric_digest: calibration.digest)
        refuse!("You have already judged this CV for the current rubric.")
      end

      judgement = CalibrationJudgement.create!(job: @job, participation: @participation, rubric_digest: calibration.digest,
                                               outcome: @outcome, note: @note, judged_by: @user, created_at: @now)
      Finalize.call(@job)
      judgement
    end

    private

    def refuse!(message) = raise(Refused, message)
  end
end
