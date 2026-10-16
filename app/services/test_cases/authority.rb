module TestCases
  # Who may do what with a job's technical test (D60, plan §c, accepted with D60 at 16:36):
  # the job's consultant uploads and edits (any consultant while the job has none assigned, the
  # same rule as calibration in feature 06); HR PIC approves a version, because the case may carry
  # the client's own data. The two roles differ, so nobody approves their own upload (rule 19).
  # Owner, reviewer and admin read only.
  module Authority
    module_function

    def may_edit?(user, job) = user&.role == "consultant" && (job.consultant_id.nil? || job.consultant_id == user.id)
    def may_approve?(user) = user&.role == "hr_pic"

    def edit_refusal(user, job)
      if user&.role == "consultant"
        "The technical test of this vacancy is filled in by the consultant assigned to it."
      else
        "The technical test is filled in by the DataKita consultant; HR approves its version."
      end
    end
  end
end
