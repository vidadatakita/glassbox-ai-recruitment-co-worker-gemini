module AiReleases
  # D51 C: the numbers GlassBox Team needs before B (a person checks every text) may be relaxed, per job or
  # across all jobs. Counted from the append-only records, never from a cache.
  #
  #   cvs            CVs that reached the release step: distinct participations with at least one
  #                  cv_screening release version (the denominator for the first three rates).
  #   released       versions released by a reviewer ("Kirim ke AI").
  #   residual       CVs whose FIRST prepared version had residual-check findings (the automatic
  #                  layers missed a shape; the reviewer had to cut or decline).
  #   cut            CVs where the reviewer removed at least one line (the person caught something
  #                  the automatic layers did not block). This is the figure that says what B adds.
  #   declined       versions the reviewer declined ("Tidak dikirim").
  #   answered       results produced from a released text (denominator for the model flag).
  #   model_flagged  of those, results where the model reported a protected attribute (ADR 0004
  #                  line 3).
  #
  # A rate "per 100 CVs" is shown only from MIN_FOR_RATE CVs on: 1 flag in 3 CVs reads as "33 per
  # 100" and would mislead a policy decision. Below that the screen shows the counts only.
  class PilotMeasure
    MIN_FOR_RATE = 100

    def initialize(job: nil)
      @scope = AiRelease.cv_screening
      @scope = @scope.where(job_id: job.id) if job
    end

    def cvs = @cvs ||= @scope.distinct.count(:participation_id)
    def released = @released ||= AiReleaseAction.where(ai_release_id: @scope.select(:id), action: "released").count
    def declined = @declined ||= AiReleaseAction.where(ai_release_id: @scope.select(:id), action: "declined").count
    def cut = @cut ||= @scope.where.not(supersedes_id: nil).distinct.count(:participation_id)

    def residual
      @residual ||= begin
        firsts = @scope.where(supersedes_id: nil).group(:participation_id).minimum(:id).values
        AiRelease.where(id: firsts).where("cardinality(residual_categories) > 0").count
      end
    end

    def answered = @answered ||= results.count
    def model_flagged = @model_flagged ||= results.where("cardinality(protected_attribute_categories) > 0").count

    def rate?(denominator) = denominator >= MIN_FOR_RATE

    # Per 100, one decimal; nil below MIN_FOR_RATE.
    def per_100(count, denominator)
      return nil unless rate?(denominator)

      (count * 100.0 / denominator).round(1)
    end

    private

    def results = ScreeningResult.where(ai_release_id: @scope.select(:id))
  end
end
