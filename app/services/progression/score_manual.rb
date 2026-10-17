module Progression
  # A stage scored outside the app (Tes psikologi and any other "Input atau impor" stage that is not
  # part of the S1+S2 gate): the HR PIC records attendance and, for a candidate who came, the score
  # 0-100 the external test gave, with the test date and a note. Same path as an interview score:
  # the threshold decision is written (Scoring::Decider) and the AI asked for its recommendation
  # (a failed AI never undoes the score). The HR PIC's Lanjut / Tidak Lanjut still moves the
  # candidate; the score only informs it and counts in the cumulative score.
  #
  # Built 2026-10-13 at GlassBox Team's request: before this, such a stage had no input at all and its score
  # always showed "-". The gated S2 is excluded on purpose: its score comes from the reviewer's
  # rubric (TechnicalTests::ScoreAnswer, trigger score_entries_test_score_author).
  class ScoreManual
    class Refused < StandardError; end

    SOURCE = "manual_or_import".freeze

    def self.call(**kwargs) = new(**kwargs).call
    def self.applies_to?(stage) = stage.score_source == SOURCE && !stage.gated?

    def initialize(participation:, actor:, attendance:, value: nil, tested_on: nil, note: nil, now: Time.current)
      @participation = participation
      @actor = actor
      @attendance = attendance.to_s
      @value = value.to_s.strip
      @tested_on = tested_on.to_s.strip
      @note = note.to_s.strip
      @now = now
      @stage = participation.stage
    end

    def call
      refuse!("Only the HR Admin enters this stage's score.") unless Progression.chooser?(@actor)
      refuse!("This stage's score is not entered here.") unless self.class.applies_to?(@stage)
      refuse!("This stage is already closed.") if @stage.status == "closed"
      refuse!("This stage's score is already recorded.") if @participation.score_entries.current.exists? || @participation.current_decision
      refuse!("Select whether the candidate attended.") unless %w[attended no_show].include?(@attendance)
      score = @attendance == "attended" ? parse_value : nil
      event_at = parse_date

      ActiveRecord::Base.transaction do
        Progression.open_stage!(@stage, @now)
        @participation.update!(attendance: @attendance)
        if score
          ScoreEntry.create!(participation: @participation, value: score, ratings: {}, note: @note.presence,
                             entered_by_id: @actor.id, event_at:, entered_at: @now)
        end
        Progression.redecide!(@participation, @actor, @now)
      end
      Recommend.call(participation: @participation, actor: @actor)
    end

    private

    # Accepts "78", "78.5" and the Indonesian "78,5"; one decimal, like every stage score.
    def parse_value
      refuse!("Enter a score from 0 to 100.") unless @value.match?(/\A\d{1,3}([.,]\d+)?\z/)

      number = BigDecimal(@value.tr(",", "."))
      refuse!("Enter a score from 0 to 100.") unless (0..100).cover?(number)
      Scoring::StageScore.round1(number)
    end

    # The day the test was taken, Jakarta time (noon, so the date never shifts across a timezone
    # conversion); today when left empty. A future date is refused.
    def parse_date
      return @now if @tested_on.empty?

      date = Date.iso8601(@tested_on)
      refuse!("The test date cannot be in the future.") if date > @now.in_time_zone("Asia/Jakarta").to_date
      Time.find_zone("Asia/Jakarta").local(date.year, date.month, date.day, 12)
    rescue Date::Error
      refuse!("The test date is not recognised.")
    end

    def refuse!(message) = raise(Refused, message)
  end
end
