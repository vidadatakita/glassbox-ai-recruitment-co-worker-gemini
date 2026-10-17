module Progression
  # The evidence Progression::Recommend sends for one stage participation: every stage of the same
  # application up to and including it. Structured facts only (see Recommend for the list); the
  # interviewer's note is the one free text, redacted with the candidate's name and residual-checked
  # like a CV. { data:, held: } where held means a note still shows personal data: send nothing.
  #
  # stage_advice: true (Progression::Recommend, prompt stage-advice-2026-10-16.3) adds, per screening
  # judgement, the CV passages it rests on, so the advice can weigh what the CV says and not only a
  # rating; and writes tiers and the interviewers' picks as English words, so no stored code
  # ("wajib", "tidak_lanjut") reaches that prompt (the 16 Oct test found "tidak_lanjut" in the advice
  # text). The salary advice keeps the payload its prompt was written for.
  class Evidence
    def self.call(participation, stage_advice: false) = new(participation, stage_advice:).call

    def initialize(participation, stage_advice: false)
      @participation = participation
      @application = participation.job_application
      @job = participation.stage.job
      @names = [@application.candidate&.name]
      @stage_advice = stage_advice
    end

    def call
      upto = Progression.order_of(@participation.stage)
      rows = @application.participations.includes(:stage).select { |p| Progression.order_of(p.stage) <= upto }
                         .sort_by { |p| Progression.order_of(p.stage) }
      held = false
      stages = rows.map do |p|
        evidence, note_held = evidence_for(p)
        held ||= note_held
        { stage: CandidateStatus::STAGE_LABELS.fetch(p.stage.code), score: p.current_score&.to_f, threshold: p.stage.threshold.to_f,
          attendance: p.attendance, evidence: }
      end
      { held:, data: { job_title: @job.title, stage_now: CandidateStatus::STAGE_LABELS.fetch(@participation.stage.code),
                       stages:, cumulative_score: Progression.cumulative(@application, upto: @participation.stage)&.to_f } }
    end

    private

    def evidence_for(participation)
      case participation.stage.code
      when "S1" then [screening(participation), false]
      when "S2" then [technical_test(participation), false]
      when "S3", "S5" then interview(participation)
      else [nil, false]
      end
    end

    def screening(participation)
      result = ScreeningResult.current_for([participation.id]).first
      return { status: "not yet screened by AI" } unless result

      { requirements_met: result.wajib_met,
        requirements: result.criteria.map do |c|
          next { tier: c["tier"], requirement: c["text"], judgement: c["judgement"], quote_verified: c["verified"] } unless @stage_advice

          { tier: Requirement::TIERS.fetch(c["tier"], c["tier"]).downcase, requirement: c["text"], judgement: c["judgement"],
            quote_verified: c["verified"], quotes: cv_quotes(c) }
        end }
    end

    # The passages behind one judgement, only when the quote check found every one of them (an
    # unverified quote is not evidence). Each is redacted with the candidate's name like an
    # interview note, and dropped, not sent, when the residual check or the money check still finds
    # something (D62 h5: no salary figure reaches the AI). Empty after an erasure (quote is null).
    def cv_quotes(criterion)
      return [] unless criterion["verified"]

      Screening::QuoteCheck.passages(criterion["quote"]).filter_map do |passage|
        text = MoneyText.strip(Screening::Redactor.call(passage, names: @names).text)
        text unless Screening::ResidualCheck.findings(text, names: @names).any? || MoneyText.suspicious?(text)
      end
    end

    def technical_test(participation)
      # The competency test taken while applying (TechnicalTests::BankResult): its recorded score, the
      # multiple-choice count and the written ratings with who rated them. No answer text, no names.
      bank = TechnicalTests::BankResult.for(participation.job_application)
      if bank
        return { status: "competency test taken, not scored yet" } unless bank.recorded?

        return { score: bank.score.to_f.round(1), basis: bank.basis_label, multiple_choice: "#{bank.mc_right} of #{bank.mc_total} correct",
                 written: bank.written.map { |w| { tests: w.tests, rating: w.rating, rated_by: w.basis } } }
      end

      review = TestReview.where(participation:).order(:id).last
      return { status: participation.attendance == "pending" ? "test not taken yet" : "not scored yet" } unless review

      names = review.test_attempt.test_case.criteria.index_by { |c| c.id.to_s }
      { ratings: review.ratings.map { |id, rating| { criterion: names[id.to_s]&.name, rating: } } }
    end

    # Every interviewer's current scorecard (Interview 2 may have the HR PIC and invited users), each
    # with its own redacted note and, for an invited user, their Lanjut / Tidak lanjut. Named only
    # "Assessor 1", "Assessor 2": the AI needs no interviewer's name either.
    def interview(participation)
      entries = participation.score_entries.current.order(:id).to_a
      return [{ status: participation.attendance == "no_show" ? "did not attend" : "not scored yet" }, false] if entries.empty?

      competencies = @job.competencies.index_by { |c| c.id.to_s }
      invites = participation.interviewer_invites.where(score_entry_id: entries.map(&:id)).index_by(&:score_entry_id)
      picks = UserRecommendation.where(job_application: @application).order(:id).to_a
      held = false
      scorecards = entries.each_with_index.map do |entry, i|
        ratings = entry.ratings.map do |id, rating|
          c = competencies[id.to_s]
          { competency: c&.name, rating:, anchor_1: c&.anchor_1, anchor_3: c&.anchor_3, anchor_5: c&.anchor_5 }
        end
        card = { interviewer: "Assessor #{i + 1}", role: invites[entry.id] ? "user (hiring manager)" : "HR", ratings: }
        if (invite = invites[entry.id])
          pick = picks.reverse.find { |r| r.user_name == invite.interviewer_name && r.created_at <= invite.submitted_at + 1.second }
          card[:recommendation] = @stage_advice && pick ? UserRecommendation::PICKS.fetch(pick.pick, [pick.pick]).first.downcase : pick&.pick
        end
        note = entry.note.to_s.strip
        unless note.empty?
          # Money too (D62 h5: no salary figure ever reaches the AI): stripped by MoneyText, and the
          # note is held when a money shape survives the strip (fail closed, engine 11 F-12).
          redacted = MoneyText.strip(Screening::Redactor.call(note, names: @names).text)
          if Screening::ResidualCheck.findings(redacted, names: @names).any? || MoneyText.suspicious?(redacted)
            held = true
          else
            card[:note] = redacted
          end
        end
        card
      end
      [{ scorecards: }, held]
    end
  end
end
