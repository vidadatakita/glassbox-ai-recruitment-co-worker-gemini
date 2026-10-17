module TestCases
  # Brief step 5, competency test bank (FLOW §7, 17 Oct 2026): every change the HR Admin makes to the
  # bank. Which version is changed:
  #   - the newest version is a DRAFT: it is edited in place;
  #   - it is SUBMITTED: refused (the HR Admin or the HR Manager returns it to draft first);
  #   - it is APPROVED, or there is none: version n + 1 is created as a copy of the newest one, and
  #     from version 2 on it needs a reason.
  # Actions: "settings" (draws, time limit), "add", "update" and "remove" a question, and "accept_ai"
  # (adds the questions the HR Admin ticked from an AI proposal, TestCases::DraftBank). A draft may be
  # half-filled; completeness is checked at submission (TestCases::BankReadiness). One transaction:
  # the bank, its questions and the audit row, or nothing.
  class SaveBank
    Result = Data.define(:ok, :errors, :bank) do
      def ok? = ok
    end
    Refused = Class.new(StandardError)
    ACTIONS = %w[settings add update remove accept_ai].freeze

    def self.call(**kwargs) = new(**kwargs).call

    # params: technical_draw, role_draw, time_limit_minutes, new_version_reason (settings);
    #         section, kind, link_id, prompt, options { "0" => text, ... }, correct (option slot key),
    #         anchor_1, anchor_3, anchor_5 (add / update); picks [] (accept_ai: indexes into the proposal).
    # source: "import" when TestCases::ImportBank adds a row (manual otherwise; "ai" via accept_ai).
    def initialize(job:, actor:, action:, params: {}, question_id: nil, suggestion: nil, source: "manual", now: Time.current)
      @job = job
      @actor = actor
      @action = action.to_s
      @raw = params.to_h.with_indifferent_access
      @params = Briefs::Params.new(@raw)
      @question_id = question_id
      @suggestion = suggestion
      @source = BankQuestion::SOURCES.key?(source) ? source : "manual"
      @now = now
      @errors = []
    end

    def call
      authorize!
      ActiveRecord::Base.transaction do
        @job.lock!
        @bank = target
        raise Refused if @errors.any?

        @bank.save! if @bank.new_record? || @bank.changed?
        copy_questions if @copied
        send(:"apply_#{@action}")
        raise Refused if @errors.any?

        audit
      end
      Result.new(true, [], @bank)
    rescue Refused
      Result.new(false, @errors, @bank)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(false, @errors + e.record.errors.full_messages, @bank)
    end

    private

    def authorize!
      @errors << "Unknown change." unless ACTIONS.include?(@action)
      @errors << Authority.edit_refusal(@actor, @job) unless Authority.may_edit_bank?(@actor, @job)
      raise Refused if @errors.any?
    end

    def target
      latest = QuestionBank.latest_for(@job)
      return latest if latest&.editable?

      if latest&.submitted?
        @errors << "Version #{latest.version} is submitted for the HR Manager's approval. Return it to draft before changing it."
        return latest
      end
      reason = @params.text(:new_version_reason)
      @errors << "The reason for the new version is required, because version #{latest.version} is already approved." if latest && reason.nil?
      @copied = latest
      QuestionBank.new(job: @job, version: (latest&.version || 0) + 1, created_by: @actor, new_version_reason: reason,
                       technical_draw: latest&.technical_draw || QuestionBank::DEFAULT_TECHNICAL_DRAW,
                       role_draw: latest&.role_draw || QuestionBank::DEFAULT_ROLE_DRAW,
                       time_limit_minutes: latest&.time_limit_minutes || QuestionBank::DEFAULT_TIME_LIMIT)
    end

    # A new version starts as a copy of the newest one, so "change one thing" means one thing.
    def copy_questions
      @copied.questions.each do |q|
        @bank.questions.create!(q.slice(:section, :kind, :position, :activity_id, :activity_text, :competency_id, :competency_name,
                                        :prompt, :options, :correct_index, :anchor_1, :anchor_3, :anchor_5, :source))
      end
    end

    def apply_settings
      { technical_draw: [1..QuestionBank::MAX_DRAW, "Technical questions drawn per applicant"],
        role_draw: [1..QuestionBank::MAX_DRAW, "Role questions drawn per applicant"],
        time_limit_minutes: [1..QuestionBank::MAX_TIME_LIMIT, "Time limit (minutes)"] }.each do |field, (range, label)|
        next unless @params.key?(field)

        value = @params.integer(field, @errors, label)
        next if value.nil?

        range.cover?(value) ? @bank[field] = value : @errors << "#{label} #{value} is out of range; enter #{range.min} to #{range.max}."
      end
      @bank.save! if @errors.empty?
    end

    def apply_add
      question = @bank.questions.build(position: next_position, source: @source)
      assign_question(question)
      question.save! if @errors.empty?
      @touched = question
    end

    def apply_update
      question = find_question
      return if question.nil?

      assign_question(question)
      question.save! if @errors.empty?
      @touched = question
    end

    def apply_remove
      question = find_question
      return if question.nil?

      @touched = question
      question.destroy!
    end

    # Adds only the ticked rows of the proposal, as AI drafts the HR Admin has read. All or nothing:
    # if one ticked row no longer fits the brief (its activity or competency was removed since), the
    # whole batch is refused with the reason and nothing is added, so the HR Admin decides again.
    def apply_accept_ai
      rows = Array(@suggestion&.payload&.dig("bank", "questions"))
      picks = @params.list(:picks).filter_map { |p| Integer(p, exception: false) }.uniq
      @errors << "Tick at least one proposed question to add." if picks.empty?
      picks.each do |index|
        row = rows[index]
        next @errors << "Proposed question #{index + 1} does not exist." if row.nil?

        question = @bank.questions.build(position: next_position, source: "ai")
        assign_question(question, Briefs::Params.new(row.with_indifferent_access), proposal: true)
        question.save! if @errors.empty?
      end
      @accepted = picks.size
    end

    def find_question
      question = @bank.questions.find_by(id: @question_id)
      @errors << "That question is not in the bank's editable version." if question.nil?
      question
    end

    def next_position = (@bank.questions.maximum(:position) || 0) + 1

    def assign_question(question, params = @params, proposal: false)
      label = proposal ? "Proposed question" : "Question"
      section = params.choice(:section, QuestionBank::SECTIONS)
      kind = params.choice(:kind, BankQuestion::KINDS)
      return @errors << "#{label}: choose the section (technical or role competency)." if section.nil?
      return @errors << "#{label}: choose the type (multiple choice or written answer)." if kind.nil?

      question.assign_attributes(section:, kind:, prompt: params.text(:prompt).to_s, activity_id: nil, activity_text: nil,
                                 competency_id: nil, competency_name: nil)
      @errors << "#{label}: write the question." if question.prompt.blank?
      assign_link(question, params, label)
      kind == "multiple_choice" ? assign_options(question, params, label) : assign_anchors(question, params)
    end

    # link_id is "a:<activity id>" or "c:<competency id>" from the screen (activity and competency ids
    # overlap, so a bare number could pick the wrong table), or a bare id from an AI proposal whose
    # section already says the table. Its text is copied, so the question keeps what it tested.
    def assign_link(question, params, label)
      raw = params.text(:link_id).to_s
      return if raw.empty?

      prefix, digits = raw.match(/\A(?:([ac]):)?(\d+)\z/)&.captures
      return @errors << "#{label}: choose what the question tests from the list." if digits.nil?
      if prefix && (prefix == "a") != question.technical?
        return @errors << "#{label}: a #{question.technical? ? 'technical' : 'role'} question tests #{question.technical? ? 'an activity' : 'a competency'}; choose one from that group."
      end

      id = digits.to_i

      if question.technical?
        activity = @job.activities.find_by(id:)
        return @errors << "#{label}: that activity is not in this vacancy's brief." if activity.nil?

        question.assign_attributes(activity_id: activity.id, activity_text: activity.description)
      else
        competency = @job.competencies.find_by(id:)
        return @errors << "#{label}: that competency is not in this vacancy's brief." if competency.nil?

        question.assign_attributes(competency_id: competency.id, competency_name: competency.name)
      end
    end

    # options arrive as slots ("0" => "text", ...) with `correct` naming the slot of the right one.
    # Blank slots are dropped and the correct slot is mapped to its place in what remains, so a gap
    # between two options never shifts the right answer.
    def assign_options(question, params, label)
      slots = params.section(:options).sort_by { |k, _| k.to_i }.map { |k, v| [k.to_s, v.to_s.strip] }.reject { |_, v| v.empty? }
      question.assign_attributes(anchor_1: nil, anchor_3: nil, anchor_5: nil, options: slots.map(&:last))
      unless slots.size.between?(BankQuestion::MIN_OPTIONS, BankQuestion::MAX_OPTIONS)
        return @errors << "#{label}: a multiple-choice question needs #{BankQuestion::MIN_OPTIONS} to #{BankQuestion::MAX_OPTIONS} answer options."
      end
      if slots.map(&:last).map(&:downcase).uniq.size != slots.size
        return @errors << "#{label}: two answer options are the same; make each option different."
      end

      index = slots.index { |key, _| key == params.text(:correct).to_s }
      index.nil? ? @errors << "#{label}: mark the correct answer." : question.correct_index = index
    end

    def assign_anchors(question, params)
      question.assign_attributes(options: [], correct_index: nil, anchor_1: params.text(:anchor_1), anchor_3: params.text(:anchor_3),
                                 anchor_5: params.text(:anchor_5))
    end

    def audit
      change = { "question_bank_version" => [nil, @bank.version], "action" => [nil, @action] }
      change["question"] = [nil, @touched.position] if @touched
      change["ai_questions_added"] = [nil, @accepted] if @accepted
      change["new_version_reason"] = [nil, @bank.new_version_reason] if @copied && @bank.new_version_reason
      JobBriefChange.create!(job: @job, actor: @actor, actor_role: @actor.role, step: "5", changes_made: change, created_at: @now)
    end
  end
end
