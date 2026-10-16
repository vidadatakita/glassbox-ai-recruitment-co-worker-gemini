module Screening
  # Calibration per job (blueprint §4.1 step 7; D13; P9). The first 20 CVs of a job are judged by
  # BOTH the consultant (pass / eliminate, Screening::JudgeCalibration) and the AI. If they
  # disagree on pass/eliminate for MORE THAN 15%, the rubric is fixed before the AI runs alone.
  # Until calibration passes, AI results are labelled "Not yet calibrated" and no AI result
  # becomes a decision (Screening::Finalize, Screening::Review both check #passed?).
  #
  # Numbers: SIZE 20 CVs, limit 15% -> at most 3 of 20 disagreements pass; 4 fail (4/20 = 20%).
  # Integer arithmetic (disagreements x 100 > 15 x 20), so no rounding decides a boundary.
  #
  # Which 20: the first 20 S1 applications of the job by arrival (application created_at, id)
  # that may be screened at all (a person with consent, not knocked out, not withdrawn). Fixed by
  # arrival, so the set cannot be chosen after seeing the AI's answers.
  #
  # Everything is keyed to the CURRENT rubric digest: after the rubric is fixed, old AI results and
  # old consultant judgements no longer count, and both judge again.
  #
  # The AI side of a pair is its pass/eliminate at the stage's current threshold (Score.outcome),
  # whether or not a quote was unverified: calibration measures the rubric, and an unverified
  # quote goes to the reviewer anyway.
  class Calibration
    SIZE = 20
    MAX_DISAGREEMENT_PERCENT = 15

    Row = Data.define(:participation, :result, :judgement, :ai_outcome) do
      def pair? = !result.nil? && !judgement.nil?
      def disagree? = pair? && ai_outcome.to_s != judgement.outcome
    end

    attr_reader :job, :stage, :digest

    def initialize(job)
      @job = job
      @stage = job.stages.find_by(code: "S1", score_source: "ai")
      @digest = Rubric.for(job).digest
    end

    def applicable? = !stage.nil?

    def participations
      return [] unless applicable?

      @participations ||= stage.participations.joins(:job_application).includes(job_application: :candidate)
                               .where.not(job_applications: { candidate_id: nil })
                               .where.not(job_applications: { consent_at: nil })
                               .where(job_applications: { consent_withdrawn_at: nil })
                               .where.not(job_applications: { status: "withdrawn" })
                               .order("job_applications.created_at", "job_applications.id").to_a
                               .reject { |p| p.job_application.knocked_out? }.first(SIZE)
    end

    def rows
      @rows ||= begin
        ids = participations.map(&:id)
        results = ScreeningResult.current_for(ids).where(rubric_digest: digest).index_by(&:participation_id)
        judgements = CalibrationJudgement.where(participation_id: ids, rubric_digest: digest).index_by(&:participation_id)
        participations.map do |p|
          result = results[p.id]
          Row.new(participation: p, result:, judgement: judgements[p.id], ai_outcome: result && ai_outcome(result))
        end
      end
    end

    def ai_outcome(result)
      Score.outcome(wajib_met: result.wajib_met, score: result.score, threshold: stage.threshold).outcome
    end

    def member?(participation) = participations.any? { |p| p.id == participation.id }
    def pairs = rows.select(&:pair?)
    def disagreements = rows.count(&:disagree?)
    def judged_count = rows.count { |r| r.judgement }

    def status
      return :not_applicable unless applicable?
      return :failed if disagreements * 100 > MAX_DISAGREEMENT_PERCENT * SIZE
      return :passed if pairs.size == SIZE

      :in_progress
    end

    def passed? = status == :passed

    # Shown as a whole percent of the pairs judged so far (display only; the rule uses the counts).
    def disagreement_percent = pairs.empty? ? 0 : (disagreements * 100.0 / pairs.size).round

    def disagreement_for(participation) = rows.find { |r| r.participation.id == participation.id }&.disagree?
  end
end
