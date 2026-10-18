# Labels for the gate "CV screening and technical test" (D60). Screen text is English (A3).
module GateHelper
  STAGE_STATUS = { "draft" => ["Not yet open", "muted"], "open" => ["Open", "info"], "closed" => ["Closed", "success"] }.freeze

  def gate_status_badge(stage)
    label, tone = STAGE_STATUS.fetch(stage.status)
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end

  def gate_result_badge(result)
    content_tag(:span, Gates::Result::LABELS.fetch(result), class: "portal-state portal-state--#{Gates::Result::TONES.fetch(result)}")
  end

  # One stage decision as a short state. A rule decision says which rule; never a score here.
  def gate_decision_badge(decision)
    return content_tag(:span, "Not decided yet", class: "portal-state portal-state--muted") if decision.nil?

    label, tone =
      case [decision.outcome, decision.reason_code]
      in ["eliminate", "gate_eliminated"] then ["Not assessed: eliminated at CV screening", "muted"]
      in ["eliminate", "no_show"] then ["Not taken", "danger"]
      in ["eliminate", "knockout"] then ["Eliminated: must-have requirement", "danger"]
      in ["eliminate", "withdrew"] then ["Withdrew consent", "muted"]
      in ["eliminate", _] then ["Not passed", "danger"]
      in ["pass", _] then ["Passed", "success"]
      else ["Needs review", "warning"]
      end
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end
end
