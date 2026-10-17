module ApplicationDrafts
  # Submit: the draft becomes an application through Portal::SubmitApplication (the window, the quota
  # and every field rule are checked again there, inside its lock). Then, in the same transaction:
  #   - each multiple-choice answer is marked correct or not from the bank's answer key (by rule, never
  #     the AI); written answers wait for scoring (slice C);
  #   - the S2 participation is marked attended: the applicant took the competency test while applying,
  #     so the 48-hour case test never turns into an unfair no-show (TechnicalTests::Expire only marks a
  #     PENDING participation);
  #   - the draft keeps the draw and the answers, linked to the application; its personal fields and its
  #     CV attachment are cleared (the application holds them now; one copy of personal data).
  # Allowed after the time is over: "time up submits what is answered" (Vida 17 Oct 2026).
  class Submit
    Result = Data.define(:application, :token, :errors, :knocked_out, :field_errors)

    def self.call(**kwargs) = new(**kwargs).call

    # after_close: true only from the automatic send at the end of the test (see
    # Portal::SubmitApplication#initialize): a closed portal does not refuse a draft whose test started.
    def initialize(draft:, now: Time.current, after_close: false)
      @draft = draft
      @now = now
      @after_close = after_close
    end

    def call
      return Result.new(nil, nil, ["This application is already submitted."], false, {}) if @draft.submitted?
      return Result.new(nil, nil, ["Upload your CV first (step 2)."], false, {}) unless @draft.cv.attached?
      return Result.new(nil, nil, ["Start the competency test first (step 3)."], false, {}) unless @draft.test_started?

      result = nil
      ActiveRecord::Base.transaction do
        # lock! reloads the row: a second Submit racing the first sees it submitted here and is told
        # so, instead of failing on the cleared personal fields (independent test pass, slice B, F3).
        @draft.lock!
        if @draft.submitted?
          result = Result.new(nil, nil, ["This application is already submitted."], false, {})
          raise ActiveRecord::Rollback
        end
        result = Portal::SubmitApplication.call(job: @draft.job, params: person_params, channel_code: @draft.channel_code, now: @now, draft: @draft,
                                                after_close: @after_close)
        raise ActiveRecord::Rollback if result.errors.any?

        score_choices
        mark_attended(result.application)
        @draft.update!(submitted_at: @now, job_application: result.application, name: nil, email: nil, phone: nil,
                       domicile_city: nil, expected_salary_min: nil, expected_salary_max: nil)
        @draft.cv.detach
      end
      return Result.new(nil, nil, result.errors, false, result.field_errors) if result.errors.any?

      Result.new(result.application, result.token, [], result.knocked_out, {})
    end

    private

    def person_params
      { name: @draft.name, email: @draft.email, phone: @draft.phone, consent: "1", knockout: @draft.knockout_answers,
        domicile_city: @draft.domicile_city, expected_salary_min: @draft.expected_salary_min&.to_s, expected_salary_max: @draft.expected_salary_max&.to_s }
    end

    def score_choices
      @draft.answers.includes(:bank_question).each do |answer|
        question = answer.bank_question
        answer.update_columns(correct: answer.choice_index == question.correct_index) if question.multiple_choice?
      end
    end

    def mark_attended(application)
      participation = TechnicalTests.participation_for(application)
      participation&.update!(attendance: "attended") if participation&.attendance == "pending"
    end
  end
end
