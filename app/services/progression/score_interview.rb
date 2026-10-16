module Progression
  # AI Builder Cup step 06, Interview 1 (HR): the HR PIC records attendance and, for a candidate who
  # came, a 1-5 rating per competency of the stage and a note. The stage score is computed
  # (Scoring::StageScore), the threshold decision written (Scoring::Decider), and the AI asked for
  # its recommendation at once (a failed AI never undoes the score).
  class ScoreInterview
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(participation:, actor:, attendance:, ratings: {}, note: nil, now: Time.current)
      @participation = participation
      @actor = actor
      @attendance = attendance.to_s
      @raw = ratings.to_h.transform_keys(&:to_s)
      @note = note.to_s.strip
      @now = now
      @stage = participation.stage
    end

    def call
      refuse!("Only the HR owner enters the interview scoring.") unless @actor&.role == CHOOSER
      refuse!("This stage is not an interview.") unless @stage.score_source == "scorecard"
      refuse!("This stage is already closed.") if @stage.status == "closed"
      refuse!("This interview scoring is already recorded.") if @participation.score_entries.current.exists? || @participation.current_decision
      refuse!("An invited assessor is still scoring; wait for their score.") if @participation.interviewer_invites.where(submitted_at: nil).exists?
      refuse!("Select whether the candidate attended.") unless %w[attended no_show].include?(@attendance)
      ratings = @attendance == "attended" ? parse_ratings : {}

      ActiveRecord::Base.transaction do
        Progression.open_stage!(@stage, @now)
        @participation.update!(attendance: @attendance)
        if ratings.any?
          ScoreEntry.create!(participation: @participation, value: Scoring::StageScore.from_ratings(ratings.values),
                             ratings:, note: @note.presence, entered_by_id: @actor.id, event_at: @now, entered_at: @now)
        end
        Progression.redecide!(@participation, @actor, @now)
      end
      Recommend.call(participation: @participation, actor: @actor)
    end

    private

    def parse_ratings = Progression.parse_ratings(@stage, @raw) { |message| refuse!(message) }

    def refuse!(message) = raise(Refused, message)
  end
end
