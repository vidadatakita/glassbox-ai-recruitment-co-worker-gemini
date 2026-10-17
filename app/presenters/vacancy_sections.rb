# frozen_string_literal: true

# The vacancy page's sections as folds (Vida, 17 Oct 2026: the same behaviour as the applicant page).
# Each section is Done (folded), To do (open) or Waiting (folded), read from the section's own records,
# not from the stepper: the stepper marks a step done at its FIRST occurrence, while a section stays
# work to do as long as applicants keep arriving. Overview and History sections are reference: the
# overview starts open, the history folded. Also maps each Hiring progress step to the section it opens.
class VacancySections
  def initialize(job, board:)
    @job = job
    @board = board
  end

  def screening = @screening ||= ScreeningBoard.new(@job)
  def gate = @gate ||= GateBoard.new(@job)

  def state(key)
    case key
    when :brief then @job.brief_complete? ? "done" : "todo"
    when :portal then portal_state
    when :screening then screening_state
    when :gate then hiring_done? ? "done" : { "draft" => "waiting", "open" => "todo", "closed" => "done" }.fetch(gate.s1.status, "todo")
    when :applicants then applicants_state
    when :funnel then "overview"
    when :window_log then "history"
    end
  end

  # Step key => element id of the section that step belongs to. A section that is not drawn (no AI
  # screening stage, no gate) is never a target, so a click never scrolls to nothing.
  def section_ids
    screening_id = screening.applicable? ? "screening" : "applicants"
    { brief: "vacancy-brief", test: "vacancy-brief", ad: "applicant-portal", open: "applicant-portal",
      release: screening_id, decision: gate.applicable? ? "gerbang-seleksi" : screening_id,
      interview: "applicants", salary: "applicants", close: "applicant-portal" }
  end

  private

  # Portal closed and every place filled (VacancyNextStep): the gate has nothing left to decide, even
  # while its stage is still formally open (Vida, 17 Oct 2026).
  def hiring_done? = @hiring_done ||= VacancyNextStep.for(@job, @board.window).done

  def portal_state
    state = @board.window.state
    state.to_s.start_with?("closed_by") && state != :closed_by_settings ? "done" : "todo"
  end

  # To do while anything waits for a person or the AI, or while the portal is open (more CVs arrive).
  def screening_state
    return "waiting" if screening.participations.empty?
    pending = screening.failed + screening.unreadable + screening.not_sent + screening.queued +
              screening.awaiting_release + screening.waiting + screening.to_review
    pending.any? || @board.window.state == :open ? "todo" : "done"
  end

  def applicants_state
    return "waiting" if @board.rows.empty?
    HiringProgress.new(@job).complete? ? "done" : "todo"
  end
end
