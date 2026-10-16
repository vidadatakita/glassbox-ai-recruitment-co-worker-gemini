# AI Builder Cup step 06: moving a candidate between stages. The AI recommends (Recommend), the HR
# PIC scores the interview (ScoreInterview) and chooses (Choose); the choice moves the candidate.
# A "step" is one stage, or the S1+S2 gate as one: its choice and recommendations hang on the S1
# participation.
module Progression
  CHOOSER = "hr_pic".freeze

  module_function

  def order_of(stage) = Stage::CODES.index(stage.code)

  # A required note made only of invisible characters is no note (engine 11 F-04/F-14, ported in the
  # 2026-10-12 merge): zero-width spaces, NBSP, LRM/RLM, soft hyphen, braille blank, hangul fillers and
  # every other code point in the generated list app/models/invisible_characters.rb count as empty.
  def blank_note?(text) = text.to_s.gsub(InvisibleCharacters::CLASS, "").strip.empty?

  # The participation a step's recommendation and choice belong to: S1 for the gate.
  def step?(participation)
    stage = participation.stage
    !stage.gated? || stage.code == "S1"
  end

  # The application's participations of the same step (both gate members, or just this one).
  def step_members(participation)
    codes = participation.stage.gate_members.map(&:code)
    participation.job_application.participations.includes(:stage).select { |p| codes.include?(p.stage.code) }
  end

  # The job's next stage after this step, by code order (RC last); nil after the last stage.
  def next_stage(participation)
    after = participation.stage.gate_members.map { |s| order_of(s) }.max
    participation.stage.job.stages.select { |s| order_of(s) > after }.min_by { |s| order_of(s) }
  end

  # Blueprint §2.2 rule 6, over the stages this application has a score for, one decimal; upto: a
  # stage, so a step's panel counts only that stage and the ones before it.
  def cumulative(application, upto: nil)
    rows = application.participations.includes(:stage).to_a
    rows = rows.select { |p| order_of(p.stage) <= order_of(upto) } if upto
    scores = rows.to_h { |p| [p.stage.code, p.current_score] }
    value = Scoring::Cumulative.call(scores, rows.to_h { |p| [p.stage.code, p.stage.weight] })
    value && Scoring::StageScore.round1(value)
  end

  # A 1-5 rating for every competency the stage assesses, keyed by competency id; yields the
  # refusal message otherwise.
  def parse_ratings(stage, raw)
    competencies = stage.job.competencies.where(stage_code: stage.code).to_a
    yield "This vacancy has no competencies for this stage yet (brief step 4)." if competencies.empty?
    competencies.to_h do |c|
      value = Integer(raw.to_h[c.id.to_s].to_s, exception: false)
      yield "Give a score from 1 to 5 for every competency." unless value && Scoring::StageScore::RATING_RANGE.cover?(value)

      [c.id.to_s, value]
    end
  end

  # The threshold decision for the participation's current score (re-written when another
  # interviewer's score changes the mean). A person's manual decision is never replaced here.
  def redecide!(participation, actor, now)
    stage = participation.stage.reload
    result = Scoring::Decider.decide(score: participation.current_score, threshold: stage.threshold,
                                     attendance: participation.attendance.to_sym, review_below_threshold: stage.review_below_threshold)
    current = participation.current_decision
    return current if current&.basis == "manual"
    return current if current && [current.outcome, current.basis, current.reason_code] == [result.outcome.to_s, result.basis.to_s, result.reason_code]

    Decision.create!(participation:, outcome: result.outcome.to_s, basis: result.basis.to_s, reason_code: result.reason_code,
                     decided_by_id: actor.id, decided_at: now, supersedes: current)
  end

  # Opens the participation's stage (the gate, for S1/S2) if it is still a draft: a decision is
  # never written on a draft stage (D37), and candidates already waiting in it means it has begun.
  def open_stage!(stage, now)
    Stages::Open.call(stage:, now:) if stage.reload.status == "draft"
  end
end
