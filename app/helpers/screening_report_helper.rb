# Feature 08 labels for the "Screening report". Colour always travels with a word (SPEC §1);
# screen text is English. Visibility comes from the board.
module ScreeningReportHelper
  def report_person(row, board)
    board.visibility.name_for?(row.application) ? (row.candidate&.name || row.person_number) : row.person_number
  end

  # AI-returned text for display: masked for blind viewers (ScreeningReportBoard#ai_text, F-01).
  def report_ai(text, row) = @board.ai_text(row, text)

  def report_state(word, tone) = content_tag(:span, word, class: "portal-state portal-state--#{tone}")

  def report_label_badge(row)
    return content_tag(:span, "None yet", class: "text-muted") if row.label_key.nil?

    badge = report_state(ScreeningReport::Labels.word(row.label_key), ScreeningReport::Labels.tone(row.label_key))
    note = row.label_confirmed ? "confirmed by reviewer" : "AI advice"
    safe_join([badge, content_tag(:small, note, class: "report-cell__note")])
  end

  def report_gate_badge(row) = report_state(ScreeningReport::GateCell.word(row.gate), ScreeningReport::GateCell.tone(row.gate))

  def report_budget_badge(row) = report_state(ScreeningReport::Budget.label(row.budget), ScreeningReport::Budget.tone(row.budget))

  def report_ai_score(row)
    return content_tag(:span, "Hidden until you judge this calibration CV", class: "text-muted") if row.blinded
    return content_tag(:span, "Not assessed by the AI", class: "text-muted") if row.ai_score.nil?

    safe_join([content_tag(:strong, "#{row.band}/5", class: "report-score"),
               content_tag(:small, "score #{ScreeningReport::Text.score(row.ai_score)}", class: "report-cell__note")])
  end

  def report_test_score(cell)
    return content_tag(:strong, ScreeningReport::Text.score(cell.score), class: "report-score") if cell.state == :scored

    tone = { expired: "muted", gate_eliminated: "muted", none: "muted" }.fetch(cell.state, "info")
    report_state(cell.label, tone)
  end

  def report_salary(application)
    ScreeningReport::Text.salary(application.expected_salary_min, application.expected_salary_max)
  end
end
