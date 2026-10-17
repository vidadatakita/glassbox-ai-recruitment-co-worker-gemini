# frozen_string_literal: true

# The applicant's score matrix (applicant page, 17 Oct 2026): one row per stage of the vacancy with its
# weight, score, pass score and result, and its weighted contribution to the cumulative score; plus the
# CV screening's rating per requirement. Display only: the numbers come from Scoring::Cumulative, the
# same rule as Progression.cumulative, so the contributions add up to the cumulative shown elsewhere.
#
# blinded: a callable (participation -> true/false), the view's ai_result_blinded? (D13): a blinded
# stage shows "hidden" and is left out of the cumulative here too, exactly as on the stage panel.
class ScoreMatrix
  Row = Data.define(:code, :label, :weight, :score, :threshold, :outcome, :contribution, :hidden)
  Criterion = Data.define(:text, :tier, :judgement, :quote, :verified)

  TIER_LABELS = { "wajib" => "Must-have", "sebaiknya" => "Should-have", "nilai_tambah" => "Nice-to-have" }.freeze
  OUTCOME_LABELS = { "pass" => "Passed", "eliminate" => "Not passed", "review" => "Under review" }.freeze

  def initialize(application, blinded: ->(_participation) { false })
    @application = application
    @blinded = blinded
    @participations = application.participations.includes(:stage).index_by { |p| p.stage.code }
  end

  def rows
    @rows ||= begin
      stages = @application.job.stages.to_a.sort_by { |s| Stage::CODES.index(s.code) || 99 }
      visible = stages.filter_map do |stage|
        p = @participations[stage.code]
        [stage.code, p.current_score] if p && !@blinded.call(p) && p.current_score
      end.to_h
      total_weight = stages.select { |s| visible.key?(s.code) }.sum(&:weight)
      stages.map do |stage|
        p = @participations[stage.code]
        hidden = p.present? && @blinded.call(p)
        score = hidden ? nil : p&.current_score
        contribution = score && total_weight.positive? ? (score.to_r * stage.weight / total_weight) : nil
        Row.new(stage.code, CandidateStatus::STAGE_LABELS.fetch(stage.code, stage.code), stage.weight, score, stage.threshold,
                (hidden ? nil : p&.current_decision&.outcome), contribution, hidden)
      end
    end
  end

  # The weighted mean over the scored stages (Scoring::Cumulative), rounded like everywhere else.
  def cumulative
    sum = rows.filter_map(&:contribution).sum
    rows.any?(&:contribution) ? Scoring::StageScore.round1(sum) : nil
  end

  def any_hidden? = rows.any?(&:hidden)

  # The latest CV screening's judgement per requirement (empty when not screened, or blinded).
  def criteria
    s1 = @participations["S1"]
    return [] if s1.nil? || @blinded.call(s1)

    result = s1.screening_results.order(:id).last
    Array(result&.judgements).map do |j|
      Criterion.new(j["text"], TIER_LABELS.fetch(j["tier"], j["tier"]), j["judgement"], j["quote"], j["verified"])
    end
  end
end
