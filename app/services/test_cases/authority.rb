module TestCases
  # Who may do what with a job's technical test (D60, plan §c; three roles since 17 Oct 2026):
  # the HR Admin who is the job's consultant uploads and edits (any HR Admin while the job has none
  # assigned, the same rule as calibration in feature 06), and the superadmin; an HR Admin or the
  # superadmin approves a version. NOTE: since the upload and approval roles merged, the same person
  # can approve their own upload (rule 19 is no longer enforced by role; the per-person rule is a
  # team decision pending on 17 Oct 2026). The HR Manager reads only.
  module Authority
    module_function

    def may_edit?(user, job) = user&.role.in?(%w[hr_admin superadmin]) && (job.consultant_id.nil? || job.consultant_id == user.id)
    def may_approve?(user) = user&.role.in?(%w[hr_admin superadmin])

    # Competency test bank (FLOW §7, 17 Oct 2026): the HR Admin who edits the test builds and submits
    # the bank (the same people as may_edit?); the HR Manager or the superadmin approves or returns it,
    # and never the person who created or submitted that bank version (maker is not the checker,
    # enforced by person; Vida 17 Oct 2026). The SUPERADMIN is exempt from the person rule (Vida
    # 10:43: the superadmin may create, submit and approve). The trigger question_banks_freeze repeats it.
    def may_edit_bank?(user, job) = may_edit?(user, job)

    def may_review_bank?(user, bank)
      return true if user&.role == "superadmin"

      user&.role == "hr_manager" && user.id != bank.created_by_id && user.id != bank.submitted_by_id
    end

    def review_bank_refusal(user, bank)
      return "The person who created this question bank cannot approve it; another HR Manager approves it." if user && user.id == bank.created_by_id
      return "The person who submitted this question bank cannot approve it; another HR Manager approves it." if user && user.id == bank.submitted_by_id

      "The question bank is approved by the HR Manager."
    end

    def edit_refusal(user, job)
      if user&.role.in?(%w[hr_admin superadmin])
        "The technical test of this vacancy is filled in by the consultant assigned to it."
      else
        "The technical test is filled in by the DataKita consultant; HR approves its version."
      end
    end
  end
end
