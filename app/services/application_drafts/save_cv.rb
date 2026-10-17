module ApplicationDrafts
  # Step 2: the CV, checked by its content exactly as in the two-step form
  # (Portal::SubmitApplication.cv_problem). A new upload replaces the earlier one until Submit.
  module SaveCv
    module_function

    # Returns nil when stored, otherwise the sentence to show.
    def call(draft, file)
      return "This application is already submitted." if draft.submitted?

      problem = Portal::SubmitApplication.cv_problem(file)
      return problem if problem

      draft.cv.attach(file)
      nil
    end
  end
end
