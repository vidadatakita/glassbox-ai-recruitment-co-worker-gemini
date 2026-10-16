module Progression
  # AI Builder Cup step 07: an invited interviewer submits from the link: 1-5 per competency, a note,
  # and their Lanjut / Tidak lanjut. Blind: the page shows no other score and no AI advice. Then:
  # the score is a ScoreEntry (attributed to the HR PIC who issued the link, the interviewer named on
  # the invite), the stage decision follows the new mean, the pick is the job's Rekomendasi User,
  # the link is used up, and the AI's recommendation for HR is refreshed in the background.
  class SubmitInterviewerScore
    class Refused < StandardError; end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(link:, ratings:, note:, pick:, now: Time.current)
      @link = link
      @invite = link.subject
      @participation = @invite.participation
      @raw = ratings.to_h.transform_keys(&:to_s)
      @note = note.to_s.strip
      @pick = pick.to_s
      @now = now
    end

    def call
      stage = @participation.stage
      refuse!("This scoring has already been sent. Thank you.") if @invite.submitted?
      refuse!("This stage is already closed.") if stage.status == "closed" || @participation.progression_choice
      ratings = Progression.parse_ratings(stage, @raw) { |message| refuse!(message) }
      refuse!("Select your pick: Continue or Do not continue.") unless UserRecommendation::PICKS.key?(@pick)
      refuse!("A reason is required for a Do not continue pick.") if @pick == "tidak_lanjut" && @note.empty?

      issuer = @invite.issued_by
      ActiveRecord::Base.transaction do
        Progression.open_stage!(stage, @now)
        @participation.update!(attendance: "attended") unless @participation.attendance == "attended"
        entry = ScoreEntry.create!(participation: @participation, value: Scoring::StageScore.from_ratings(ratings.values),
                                   ratings:, note: @note.presence, entered_by_id: issuer.id, event_at: @now, entered_at: @now)
        Progression.redecide!(@participation, issuer, @now)
        @invite.update!(score_entry: entry, submitted_at: @now)
        UserRecommendation.create!(job_application: @participation.job_application, user_name: @invite.interviewer_name,
                                   pick: @pick, note: @note.presence, entered_by: issuer, created_at: @now)
        @link.update!(used_at: @now)
      end
      StageRecommendJob.perform_later(@participation.id, issuer.id)
      @invite
    end

    private

    def refuse!(message) = raise(Refused, message)
  end
end
