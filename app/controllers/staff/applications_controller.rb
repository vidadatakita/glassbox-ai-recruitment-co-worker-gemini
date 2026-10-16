module Staff
  # Pelamar detail (part of screen 7): stages, schedule, offer upload, objection answers.
  class ApplicationsController < BaseController
    # A candidate's detail, contact data and CV: the people who run or decide the job (BP §1.2;
    # D40: the owner yes). Admin manages clients, packages and users, not candidates (test engine F13).
    before_action -> { require_role!(:hr_pic, :consultant, :reviewer, :owner) }
    def show
      @application = org_find(JobApplication.includes(:candidate, participations: :stage), params[:id])
      @job = @application.job
      @offers = @application.offer_documents.order(version: :desc)
    end

    # CVs are private files: served only through this logged-in action, never a public URL (§4.2).
    def cv
      application = org_find(JobApplication, params[:id])
      return head(:not_found) unless application.cv.attached?
      # D62 h7 / engine 07 F-01: the CV identifies the candidate; same rule as every staff screen.
      return head(:not_found) unless CandidateIdentity.visible_to?(current_user, application)

      bytes = application.cv.download
      # A .docx is downloaded (browsers cannot show it inline); a PDF opens in the browser.
      if Screening::CvText.kind(bytes) == "docx"
        response.headers["X-Content-Type-Options"] = "nosniff"
        send_data bytes, filename: "cv-#{application.id}.docx", type: Screening::CvText::DOCX, disposition: "attachment"
      else
        send_data bytes, filename: "cv-#{application.id}.pdf", type: "application/pdf", disposition: "inline"
      end
    end
  end
end
