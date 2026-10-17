# The AI interview inside the apply flow (docs/superpowers/specs/2026-10-16-ai-interview-design.md): five
# chat questions after the application, before S1. Reached only through the candidate's private status
# link; a tampered, revoked or withdrawn link gets the one "link not valid" page.
#
#   GET  show    the intro (before the clock), the chat (question + answers so far), or a redirect to the
#                status page once the interview is over (it is only ever offered while open)
#   POST start   Interviews::Start: shows question 1 and starts the 30-minute clock; a GET never asks the AI
#   POST answer  Interviews::Answer (one answer per turn; checked, redacted, then the next question)
#   POST finish  the candidate ends the interview early; S1 runs on what exists
#
# Every page load first runs Interviews::Expire, so an interview past its time is closed even when the
# recurring job has not run. Forms run without Turbo (the candidate layout loads none).
class InterviewsController < CandidateController
  LIMITS = Glassbox::Settings::RATE_LIMITS
  BUSY = "The interviewer is busy right now. Your answer is saved. Please try again in a moment.".freeze
  REFUSED = "Your answer could not be sent. Check that it is not empty and has at most #{Interview::MAX_ANSWER} characters.".freeze

  rate_limit to: LIMITS[:interview_start_per_link][:to], within: LIMITS[:interview_start_per_link][:within].seconds,
             only: :start, name: "interview-start", by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_interview_path(params[:token]), alert: "Too many attempts. Try again in a few minutes." }
  rate_limit to: LIMITS[:interview_answer_per_link][:to], within: LIMITS[:interview_answer_per_link][:within].seconds,
             only: :answer, name: "interview-answer", by: -> { OneTimeLink.digest(params[:token]) },
             with: -> { redirect_to candidate_status_interview_path(params[:token]), alert: "Too many attempts. Try again in a few minutes." }

  before_action :load_link
  before_action :refuse_after_withdrawal
  before_action :load_interview

  def show
    return redirect_to(candidate_status_path(params[:token])) unless @interview&.open?

    @turns = @interview.turns.to_a
    last = @turns.last
    @current = last if last && last.answered_at.nil?
    # The last answer is stored but the next question never came (the AI was busy): offer "Try again".
    @waiting = last.present? && last.answered_at.present?
    @started = last.present?
  end

  def start
    result = Interviews::Start.call(@interview) if @interview&.open?
    return render(json: next_payload(result)) if json?

    redirect_to candidate_status_interview_path(params[:token]), alert: (BUSY if result&.status == :retry)
  end

  # "Try again" after the AI was busy: asks for the question that is missing (the first one, or the one after
  # the last answer, which is already stored).
  def next_question
    result = Interviews::Next.call(@interview) if @interview&.open?
    return render(json: next_payload(result)) if json?

    redirect_to candidate_status_interview_path(params[:token]), alert: (BUSY if result&.status == :retry)
  end

  def answer
    unless @interview&.open?
      return render(json: finished_payload) if json?

      return redirect_to(candidate_status_path(params[:token]))
    end

    result = Interviews::Answer.call(interview: @interview, text: answer_text, position: params[:position])
    return render(json: answer_payload(result), status: (result.status == :refused ? :unprocessable_entity : :ok)) if json?

    case result.status
    when :refused then redirect_to candidate_status_interview_path(params[:token]), alert: REFUSED
    when :retry then redirect_to candidate_status_interview_path(params[:token]), alert: BUSY
    when :finished then redirect_to candidate_status_path(params[:token]), notice: "Thank you. Your interview is complete."
    else redirect_to candidate_status_interview_path(params[:token])
    end
  end

  def finish
    Interviews::Finish.call(@interview, reason: "ended_by_candidate") if @interview&.open?
    return render(json: finished_payload) if json?

    redirect_to candidate_status_path(params[:token]), notice: "Thank you. Your interview is complete."
  end

  private

  # The chat page asks for JSON (fetch); without JavaScript the same actions redirect as before.
  def json? = request.format.json?

  # The JSON body or the form field, whichever the client sent.
  def answer_text = params[:answer]

  def finished_payload = { status: "finished", redirect: candidate_status_path(params[:token]) }

  # From an Interviews::Next::Result (start, next).
  def next_payload(result)
    case result&.status
    when :ok then question_payload(result.turn)
    when :retry then { status: "retry", message: BUSY }
    else finished_payload
    end
  end

  def question_payload(turn)
    { status: "accepted", next: { position: turn.position, question: turn.question },
      due_label: helpers.l(@interview.reload.due_at.in_time_zone, format: :long_wib) }
  end

  # A held answer looks exactly like an accepted one: the candidate is not told a check tripped.
  def answer_payload(result)
    case result.status
    when :refused then { status: "refused", message: REFUSED }
    when :retry then { status: "retry", message: BUSY }
    when :finished then finished_payload
    else question_payload(result.next_turn)
    end
  end

  def load_link
    @link = OneTimeLink.live("candidate_status", params[:token])
    @application = @link&.subject
    render_invalid_link if @application.nil?
  end

  def refuse_after_withdrawal
    render_invalid_link if @application.consent_withdrawn_at.present?
  end

  def load_interview
    Interviews::Expire.call(@application)
    @interview = @application.reload.interview
  end
end
