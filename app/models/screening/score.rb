module Screening
  # Blueprint §4.1 steps 4-5: the model judges each criterion; the S1 score is computed HERE, in
  # plain Ruby, so identical judgements always give the identical score. No database access.
  #
  # Score (0-100, one decimal, rounded half up like every stage score, §2.2 rule 1):
  #   sum over sebaiknya requirements of  weight x rating / 3
  # The sebaiknya weights sum to 100 (brief rule), and a rating is 0-3, so a candidate rated 3 on
  # every sebaiknya line scores 100 and one rated 0 everywhere scores 0. Dividing by 3 (the top
  # of the scale) is the builder's reading of "judged 0-3 ... weights sum to 100"; the spec gives
  # no formula. Recorded in feature record 06 §2.
  #
  # Wajib (must-have): any "not_met" -> wajib_met false -> eliminate by rule ("wajib_not_met"),
  # whatever the score (§4.1 step 4). The score is still computed and shown.
  #
  # Nilai tambah (nice-to-have): BONUS ONLY, NEVER elimination. The spec defines no bonus formula,
  # so the bonus is DISPLAY ONLY ("4 dari 6 poin nilai tambah") and does not move the score or the
  # decision. Open item for GlassBox Team (feature record 06 §8). Adding it to the score without a decided
  # formula would be an invented rule that eliminates or passes people.
  module Score
    Result = Data.define(:score, :wajib_met, :bonus_points, :bonus_possible, :unverified_count)
    TOP = 3

    module_function

    # rubric: Screening::Rubric. judgements: { "R12" => { "judgement" => "2", "verified" => true }, ... }
    # for EVERY criterion of the rubric (Screening::Run refuses an answer that misses one).
    def compute(rubric, judgements)
      missing = rubric.criteria.map(&:key) - judgements.keys
      raise ArgumentError, "judgements missing for #{missing.join(', ')}" if missing.any?

      sebaiknya = rubric.criteria.select { |c| c.tier == "sebaiknya" }
      weight_sum = sebaiknya.sum { |c| c.weight.to_i }
      raise ArgumentError, "sebaiknya weights must sum to 100, got #{weight_sum}" unless weight_sum == 100

      raw = sebaiknya.sum(Rational(0)) { |c| Rational(c.weight.to_i * rating(judgements[c.key], c), TOP) }
      wajib_met = rubric.criteria.select { |c| c.tier == "wajib" }.all? { |c| judgements[c.key]["judgement"] == "met" }
      bonus = rubric.criteria.select { |c| c.tier == "nilai_tambah" }

      Result.new(
        score: Scoring::StageScore.round1(raw),
        wajib_met:,
        bonus_points: bonus.sum { |c| rating(judgements[c.key], c) },
        bonus_possible: bonus.size * TOP,
        unverified_count: judgements.values.count { |j| j["verified"] == false }
      )
    end

    # The decision the AI result points to, at the stage's CURRENT threshold. A failed wajib is a
    # fact about the CV, not a score, so it is basis "rule" and a later threshold change never
    # re-decides it (rule 3). Otherwise the ordinary inclusive threshold rule applies (D9).
    def outcome(wajib_met:, score:, threshold:)
      return Scoring::Decider::Result.new(:eliminate, :rule, "wajib_not_met") unless wajib_met

      Scoring::Decider.decide(score:, threshold:, attendance: :attended)
    end

    def rating(judgement, criterion)
      value = judgement["judgement"].to_s
      unless value.match?(/\A[0-3]\z/)
        raise ArgumentError, "#{criterion.key} (#{criterion.tier}) needs a rating 0-3, got #{value.inspect}"
      end

      value.to_i
    end
  end
end
