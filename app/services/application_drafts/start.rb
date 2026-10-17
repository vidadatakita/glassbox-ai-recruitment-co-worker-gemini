module ApplicationDrafts
  # Step 1 of the three-step form: personal details, the knockout questions and consent, checked by the
  # same rules as the two-step form (Portal::SubmitApplication.person_errors). A knockout "No" stores
  # nothing (Vida 17 Oct 2026: the questions sit inside step 1; a "No" ends politely and keeps no data).
  # Otherwise the draft is opened with the consent the applicant was shown (signed token) and the
  # vacancy's bank in force; its secret goes into the link of steps 2 and 3.
  class Start
    Result = Data.define(:draft, :secret, :field_errors, :knocked_out) do
      def ok? = draft.present?
    end
    ConsentUnverifiable = Class.new(StandardError)

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(job:, params:, channel_code: nil, now: Time.current)
      @job = job
      @params = params
      @channel_code = channel_code.to_s[0, 40].presence
      @now = now
    end

    def call
      questions = @job.knockout_questions.order(:position).to_a
      errors = Portal::SubmitApplication.person_errors(@params, questions)
      answers = (@params[:knockout] || {}).to_h.transform_keys(&:to_s).slice(*questions.map { |q| q.id.to_s })
      # A "No" ends the application before anything is stored, even if another field is wrong.
      return Result.new(nil, nil, {}, true) if errors[:knockout].nil? && answers.value?("tidak")
      return Result.new(nil, nil, errors, false) if errors.any?

      bank = QuestionBank.current_for(@job)
      raise Portal::SubmitApplication::Closed, "no bank in force" if bank.nil? || !ApplicationWindow.new(@job, now: @now).open?

      template, retention = shown_consent
      raise ConsentUnverifiable if template.nil? || retention.nil?

      salary = ScreeningReport::ExpectedSalary.parse(@params[:expected_salary_min], @params[:expected_salary_max])
      draft, secret = ApplicationDraft.open!(
        job: @job, name: @params[:name].to_s.strip, email: @params[:email].to_s.strip.downcase, phone: @params[:phone].to_s.strip,
        domicile_city: ScreeningReport::DomicileCity.parse(@params[:domicile_city]).value,
        expected_salary_min: salary.min, expected_salary_max: salary.max, knockout_answers: answers,
        consent_template: template, consent_retention_days: retention, consent_at: @now, channel_code: @channel_code,
        question_bank: bank, time_limit_minutes: bank.time_limit_minutes
      )
      Result.new(draft, secret, {}, false)
    end

    private

    def shown_consent
      data = Portal::SubmitApplication.consent_verifier.verified(@params[:consent_token].to_s)
      return [nil, nil] unless data

      template = ConsentTemplate.where(client_company_id: [@job.client_company_id, nil]).find_by(id: data["template_id"])
      [template, Integer(data["retention_days"], exception: false)]
    end
  end
end
