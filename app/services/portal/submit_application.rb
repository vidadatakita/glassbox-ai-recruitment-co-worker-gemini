module Portal
  # Stores one application from the Lamar page (screen 10; BP §3.6 B1, rules 16; D32, D35, D36).
  #
  # The window is re-checked here, inside a transaction holding a lock on the job row, so the
  # refusal is the server's, not the form's: a POST to a closed window stores nothing, and two
  # submissions racing for the last quota place cannot both get in.
  class SubmitApplication
    class Closed < StandardError; end
    class ConsentUnverifiable < StandardError; end

    # errors: the messages, in form order. field_errors: { field => message } so the form can mark
    # the field itself (Nielsen 9: say what is wrong where it is wrong).
    Result = Data.define(:application, :token, :errors, :knocked_out, :field_errors)

    # The consent the candidate was SHOWN: the template version and the retention days on the page.
    # Signed into the form so it cannot be edited, and stored as shown (D35: "the version it agreed
    # to"; test engine F5/F6). Before this, the version and days in force at submission were stored,
    # which differ when either changes between step 1 and step 2.
    CONSENT_PURPOSE = :lamar_consent

    def self.consent_verifier = Rails.application.message_verifier(CONSENT_PURPOSE)

    def self.sign_consent(template, retention_days)
      consent_verifier.generate({ "template_id" => template.id, "retention_days" => retention_days }, expires_in: 1.day)
    end

    MAX_CV_BYTES = 5.megabytes
    ANSWERS = ["ya", "tidak"].freeze # stored answer values, not screen text

    def self.call(**kwargs) = new(**kwargs).call

    # params: name, email, phone, consent ("1"), knockout ({ question_id => "ya" | "tidak" }), cv (upload)
    # draft: an ApplicationDraft from the three-step form (17 Oct 2026). Its consent was recorded at
    # step 1 (template, retention days, time) and its CV checked at step 2, so those come from the
    # draft instead of the signed token and the upload; every other check runs as for the form.
    #
    # after_close: the three-step draft's automatic send at the end of its test (Vida, 18 Oct 2026: an
    # applicant whose test started while the portal was open is still sent, even if the portal closed
    # since). The portal's closed state (HR, date, quota) is then not checked; the first stage being
    # closed still refuses, because an application entering a closed CV screening would sit there
    # forever (D40). Only ApplicationDrafts::Submit passes it, and only for a draft whose test started.
    def initialize(job:, params:, channel_code: nil, now: Time.current, draft: nil, after_close: false)
      @job = job
      @params = params
      @channel_code = channel_code.to_s[0, 40].presence
      @now = now
      @draft = draft
      @after_close = after_close && draft&.test_started?
    end

    def call
      field_errors = validate
      if field_errors.any?
        return Result.new(application: nil, token: nil, errors: field_errors.values, knocked_out: false, field_errors:)
      end

      ActiveRecord::Base.transaction do
        @job.lock!
        window = ApplicationWindow.new(@job, now: @now)
        raise Closed, "window closed" unless window.open? || (@after_close && !window.first_stage_closed?)

        consent, retention = @draft ? [@draft.consent_template, @draft.consent_retention_days] : shown_consent
        # Without a verifiable record of what the candidate was shown, nothing is stored: a consent
        # that cannot say what it covered is not a consent (Pasal 22(1)). The form is shown again.
        raise ConsentUnverifiable if consent.nil? || retention.nil?

        candidate = Candidate.create!(name: @params[:name].strip, email: @params[:email].strip.downcase,
                                      phone: @params[:phone].strip)
        application = @job.job_applications.create!(
          candidate:, channel_code: @channel_code, knockout_answers: knockout_answers,
          consent_at: @draft&.consent_at || @now, consent_template: consent, consent_retention_days: retention,
          status: knocked_out? ? "eliminated" : "active",
          # Feature 08 (D62 h5): optional, never sent to the AI, never scored.
          expected_salary_min: expected_salary.min, expected_salary_max: expected_salary.max,
          domicile_city: domicile_city.value # D54, optional, city only, never sent to the AI
        )
        if @draft
          application.cv.attach(@draft.cv.blob)
        elsif cv.present?
          application.cv.attach(cv)
        end
        # AI interview: created before the stages, so the participation's after-commit Enqueue finds the gate.
        Interview.create!(job_application: application) if Interviews.enabled_for?(@job) && !knocked_out?
        enter_first_stage(application)
        _link, token = OneTimeLink.issue!(subject: application, purpose: "candidate_status")
        Result.new(application:, token:, errors: [], knocked_out: knocked_out?, field_errors: {})
      end
    end

    private

    # Returns { field => message } in form order; empty when valid. The person's fields are checked by
    # the same rules in the three-step form's step 1 (self.person_errors), one owner per rule.
    def validate
      errors = self.class.person_errors(@params, questions)
      unless knocked_out? || @draft
        cv_error = self.class.cv_problem(cv)
        errors[:cv] = cv_error if cv_error
      end
      errors.delete(:consent) if @draft # recorded at the draft's step 1
      errors
    end

    def self.person_errors(params, questions)
      errors = {}
      answers = (params[:knockout] || {}).to_h.transform_keys(&:to_s)
      errors[:knockout] = "Answer every requirement question with Yes or No." unless questions.all? { |q| ANSWERS.include?(answers[q.id.to_s]) }
      errors[:name] = "Full name is required." if params[:name].to_s.strip.empty?
      phone = params[:phone].to_s.gsub(/[\s-]/, "")
      if phone.empty?
        errors[:phone] = "WhatsApp number is required."
      elsif !phone.match?(/\A(\+62|62|0)8\d{7,12}\z/)
        errors[:phone] = "The WhatsApp number is not valid. Example: 0812 3456 7890."
      end
      email = params[:email].to_s.strip
      if email.empty?
        errors[:email] = "E-mail is required."
      elsif !email.match?(URI::MailTo::EMAIL_REGEXP)
        errors[:email] = "The e-mail address is not valid. Example: name@example.com."
      end
      salary = ScreeningReport::ExpectedSalary.parse(params[:expected_salary_min], params[:expected_salary_max])
      errors[:expected_salary] = salary.error if salary.error
      city = ScreeningReport::DomicileCity.parse(params[:domicile_city])
      errors[:domicile_city] = city.error if city.error
      errors[:consent] = "You need to agree to the use of your data to apply." unless params[:consent] == "1"
      errors
    end

    # nil when the upload is an acceptable CV; otherwise the sentence to show.
    def self.cv_problem(file)
      return "A CV is required (PDF or Word .docx, 5 MB at most)." if file.blank?
      return "The CV is larger than 5 MB." if file.size > MAX_CV_BYTES

      cv_format_problem(file)
    end

    # By the file's CONTENT, never only its name or the browser's type (both the sender controls):
    # a PDF by its header; a .docx through the same inspection as the technical-test files (no
    # macros, ActiveX, embedded objects or links to other files). The old binary .doc is refused
    # with a way out: it often carries macros and has no safe text reader here.
    OLE = "\xD0\xCF\x11\xE0".b

    def self.cv_format_problem(file)
      head = file.read(8).to_s.b
      file.rewind
      return if head.start_with?("%PDF-")
      return "The old Word format (.doc) is not accepted. Save the CV again as .docx or PDF, then upload it again." if head.start_with?(OLE)

      inspection = TestCases::FileInspection.call(io: file, filename: file.original_filename.to_s, allowed: %w[docx], max_bytes: MAX_CV_BYTES)
      file.rewind
      return if inspection.ok?

      "The CV must be a PDF or Word (.docx) file. #{inspection.problems.first}"
    end

    def shown_consent
      data = self.class.consent_verifier.verified(@params[:consent_token].to_s)
      return [nil, nil] unless data

      # Only a text this job's company may show: its own, or the install-wide one (multi-tenant).
      template = ConsentTemplate.where(client_company_id: [@job.client_company_id, nil]).find_by(id: data["template_id"])
      [template, Integer(data["retention_days"], exception: false)]
    end

    def questions = @questions ||= @job.knockout_questions.order(:position).to_a
    def raw_answers = (@params[:knockout] || {}).to_h.transform_keys(&:to_s)
    def knockout_answers = questions.to_h { |q| [q.id.to_s, raw_answers[q.id.to_s]] }
    def knocked_out? = questions.any? { |q| raw_answers[q.id.to_s] == "tidak" }
    def cv = @params[:cv]
    def domicile_city = @domicile_city ||= ScreeningReport::DomicileCity.parse(@params[:domicile_city])
    def expected_salary = @expected_salary ||= ScreeningReport::ExpectedSalary.parse(@params[:expected_salary_min], @params[:expected_salary_max])

    # The application enters S1 (or the job's first stage). A knockout "tidak" is decided at once
    # by rule (rule 16): eliminated, reason knockout, and the AI is never called for it.
    #
    # D60: when that stage belongs to the gate "CV screening and technical test", the application enters
    # S2 (the technical test) at the same moment, because the test follows the submitted
    # application in the apply flow. Same rules for both rows.
    def enter_first_stage(application)
      stage = @job.stages.where(code: Stage::CODES - ["RC"]).order(:code).first
      return if stage.nil?

      stage.gate_members.each { |member| enter_stage(application, member) }
    end

    def enter_stage(application, stage)
      participation = Participation.create!(job_application: application, stage:, attendance: "pending")
      # A decision is written only on an open stage (D37). On a draft stage, Stages::Open decides
      # the knockout when the stage opens; the application is already marked eliminated.
      return unless knocked_out? && stage.status == "open"

      result = Scoring::Decider.decide(score: nil, threshold: stage.threshold, attendance: :pending, knockout_failed: true)
      Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s,
                       reason_code: result.reason_code, decided_at: @now)
    end
  end
end
