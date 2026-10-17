module Screening
  # The consultant's own judgement of one calibration CV (blueprint §4.1 step 7, D13). Blind: the
  # calibration screen hides the AI's answer for a CV until the consultant has judged it, so the
  # consultant is not anchored by it (the agreement figure would otherwise measure copying).
  #
  # Who: a consultant; when the job names its consultant, that consultant.
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
      if @job.consultant_id.present? && @job.consultant_id != @user.id
        refuse!("Calibration CVs are judged by the consultant of this vacancy.")
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
