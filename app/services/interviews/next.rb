module Interviews
  # Creates the next question (the first one included), asking the AI up to three times: Gemini often
  # answers 503 for a moment, and a live chat must not end on that. The 30-minute clock starts here, when
  # the first question exists (never when the AI failed).
  #   :ok        a question is waiting (turn)
  #   :retry     the AI is busy: nothing changed, the candidate presses "Try again"
  #   :finished  the interview is over (a permanent AI error ends it, S1 runs on the CV and the answers)
  class Next
    Result = Data.define(:status, :turn)

    # Seconds to wait before attempt 2 and attempt 3. Tests set it to [0, 0].
    class_attribute :pauses, default: [0.5, 1.5]

    def self.call(interview, now: Time.current) = new(interview, now).call

    def initialize(interview, now)
      @interview = interview
      @now = now
    end

    def call
      return Result.new(:finished, nil) unless @interview.open?

      last = @interview.turns.reload.last
      return Result.new(:ok, last) if last && last.answered_at.nil?
      return Result.new(:finished, nil) if last && last.position >= Interview::MAX_TURNS

      position = (last&.position || 0) + 1
      create_turn(position, position == 1 ? opening_question : ask)
    rescue ActiveRecord::RecordNotUnique
      Result.new(:ok, @interview.turns.reload.last) # two requests raced for the same question
    rescue Screening::Errors::Permanent => e
      Rails.logger.warn("[interview] interview=#{@interview.id} AI refused kind=#{e.kind}")
      Interviews::Finish.call(@interview, reason: "ai_unavailable", now: @now)
      Result.new(:finished, nil)
    rescue Screening::Errors::Base => e
      Rails.logger.warn("[interview] interview=#{@interview.id} no question now kind=#{e.kind}")
      Result.new(:retry, nil)
    end

    private

    # Question 1 is the vacancy's one opening question: written by the AI for the first applicant, then reused,
    # so every applicant of a vacancy starts from the same question (and a busy AI does not block later ones).
    def opening_question
      job_id = @interview.job.id
      InterviewOpening.find_by(job_id:)&.question || InterviewOpening.create!(job_id:, question: ask, created_at: Time.current).question
    rescue ActiveRecord::RecordNotUnique
      InterviewOpening.find_by!(job_id:).question # two first applicants raced; the stored one wins
    end

    def ask
      attempt = 0
      begin
        Interviews::Questioner.next_question(@interview)
      rescue Screening::Errors::Transient, Screening::Errors::Malformed
        raise unless (pause = pauses[attempt])

        attempt += 1
        sleep(pause)
        retry
      end
    end

    def create_turn(position, question)
      turn = @interview.with_lock do
        @interview.update!(started_at: @now) if position == 1 && @interview.started_at.nil?
        @interview.turns.create!(position:, question:, asked_at: @now)
      end
      Result.new(:ok, turn)
    end
  end
end
