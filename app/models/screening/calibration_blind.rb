module Screening
  # D13 blind calibration, the one rule every screen and the screening report use (18 Oct 2026: the
  # report and its Excel showed the AI's score on unjudged calibration CVs to the very people who judge
  # them). While a CV is one of the job's calibration CVs and has no judgement yet, its AI score,
  # label and judgements are hidden from the people who judge calibration, so their judgement is not
  # anchored on the AI. The blinded people are exactly the ones Screening::JudgeCalibration lets judge:
  # the vacancy's consultant (any HR Admin while none is assigned) and the superadmin. Everyone else
  # does not judge, so they see the AI result.
  module CalibrationBlind
    module_function

    def judge?(user, job)
      return false unless user&.role.in?(%w[hr_admin superadmin])

      job.consultant_id.blank? || job.consultant_id == user.id || user.role == "superadmin"
    end

    # calibration: pass one Screening::Calibration per job when checking many CVs (the report).
    def blinded?(participation, user, calibration: nil)
      return false unless participation&.stage&.code == "S1" && judge?(user, participation.stage.job)

      calibration ||= Calibration.new(participation.stage.job)
      row = calibration.applicable? && calibration.rows.find { |r| r.participation.id == participation.id }
      row.present? && row.judgement.nil?
    end
  end
end
