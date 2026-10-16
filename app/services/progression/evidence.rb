module Progression
  # The evidence Progression::Recommend sends for one stage participation: every stage of the same
  # application up to and including it. Structured facts only (see Recommend for the list); the
  # interviewer's note is the one free text, redacted with the candidate's name and residual-checked
  # like a CV. { data:, held: } where held means a note still shows personal data: send nothing.
  class Evidence
    def self.call(participation) = new(participation).call

    def initialize(participation)
      @participation = participation
      @application = participation.job_application
      @job = participation.stage.job
      @names = [@application.candidate&.name]
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
        requirements: result.criteria.map { |c| { tier: c["tier"], requirement: c["text"], judgement: c["judgement"], quote_verified: c["verified"] } } }
    end

    def technical_test(participation)
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
          card[:recommendation] = pick&.pick
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
