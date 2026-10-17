# Why a vacancy's screening tools are not available, or nil when they are (Vida, 17 Oct 2026). One rule
# for the CV screening card, the screening report link and the fairness check link:
# - no CV in the pipeline yet: there is nothing to screen, report or check;
# - the vacancy is done (portal closed and every place filled, VacancyNextStep): nothing to start or
#   check, except the screening report, which stays open as the hiring record (until_done: false).
# The tools render as greyed text with this reason instead of a link or a form, never as a disabled
# submit button (house rule: a disabled control is not sent).
module VacancyToolsHelper
  # until_done: false for a tool that stays useful after the hiring (the screening report and its Excel
  # are the hiring record; Vida, 17 Oct 2026: "open report tetap aktif").
  def vacancy_tools_blocked_reason(job, board = ScreeningBoard.new(job), until_done: true)
    return "Available once the first CV is in the pipeline" if board.participations.empty?
    return "Hiring is complete: every place is filled" if until_done && VacancyNextStep.for(job, ApplicationWindow.new(job)).done

    nil
  end

  # A greyed, non-interactive stand-in for a link or button, with the reason below it.
  def waiting_tool(label, icon, reason)
    safe_join([
      content_tag(:span, safe_join([label, " ", content_tag(:i, "", class: "fa #{icon} ms-1", "aria-hidden": "true")]),
                  class: "btn btn-light disabled link-waiting", "aria-disabled": "true", title: reason),
      content_tag(:small, reason, class: "d-block text-muted mt-1")
    ])
  end
end
