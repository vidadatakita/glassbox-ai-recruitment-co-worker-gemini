# The before / after matrix on the Impact page (staff/impacts). Each row pairs the client's own
# BEFORE figure (Settings, baseline_*; nil until an admin enters it) with the figure measured from
# the records (Impact). The change is computed only when both sides exist, so the page never shows
# an improvement that rests on an invented number. Every row opens to the same figure per vacancy,
# each linking to the feature page whose records produced it.
module ImpactHelper
  ImpactRow = Data.define(:key, :measure, :icon, :basis, :before, :after, :before_text, :after_text, :count, :change, :tone, :scale)

  # Rows in the order the page reads them. Units: hours are wall-clock hours, minutes are minutes of
  # a person's reading time per CV, percentages are whole percent (0-100).
  def impact_rows(impact, baseline)
    hours = impact.hours_to_answer
    read = impact.human_read_pct
    reasoned = impact.reasoned_pct
    agree = impact.agreement_pct
    before_hours = baseline["baseline_hours_to_answer"]
    before_minutes = baseline["baseline_minutes_per_cv"]
    before_reasoned = baseline["baseline_reasoned_pct"]
    # Estimated minutes per CV after: only the CVs a person still reads cost reading time.
    after_minutes = (before_minutes * read.value / 100.0).round(1) if before_minutes && read.value

    [
      ImpactRow.new(key: :hours, measure: "Time to first answer", icon: "fa-clock-o",
                    basis: "Median hours from an application to the first AI result, decision or HR choice. #{hours.count} applications.",
                    before: before_hours, after: hours.value, before_text: impact_value(before_hours, " hours"), after_text: impact_value(hours.value, " hours"),
                    count: hours.count, scale: [before_hours, hours.value].compact.max,
                    **impact_change(before_hours, hours.value, lower_is_better: true, unit: :percent)),
      # Before AI screening a person reads every CV, so 100% is a fact of the old process, not an estimate.
      ImpactRow.new(key: :read, measure: "CVs a person still reads", icon: "fa-file-text-o",
                    basis: "Held for review, not sent, unreadable, failed or reviewed, out of #{read.count} CVs screened.",
                    before: 100, after: read.value, before_text: "100%", after_text: impact_value(read.value, "%"),
                    count: read.count, scale: 100, **impact_change(100, read.value, lower_is_better: true, unit: :points)),
      ImpactRow.new(key: :minutes, measure: "Reading time per CV", icon: "fa-hourglass-half",
                    basis: "Estimate: the client's minutes per CV times the share of CVs a person still reads.",
                    # The AFTER side is derived from the BEFORE minutes, so without them it waits for that figure.
                    before: before_minutes, after: after_minutes, before_text: impact_value(before_minutes, " min"),
                    after_text: before_minutes ? impact_value(after_minutes, " min") : "needs Before",
                    count: read.count, scale: before_minutes, **impact_change(before_minutes, after_minutes, lower_is_better: true, unit: :minutes)),
      ImpactRow.new(key: :reasoned, measure: "Decisions with a written reason", icon: "fa-pencil-square-o",
                    basis: "Continue / Do not continue choices with the chooser's note or the AI advice's reasons. #{reasoned.count} choices.",
                    before: before_reasoned, after: reasoned.value, before_text: impact_value(before_reasoned, "%"), after_text: impact_value(reasoned.value, "%"),
                    count: reasoned.count, scale: 100, **impact_change(before_reasoned, reasoned.value, lower_is_better: false, unit: :points)),
      # There is no AI advice before, so agreement has no BEFORE; it is shown as newly measurable.
      ImpactRow.new(key: :agreement, measure: "HR choices in line with the AI", icon: "fa-balance-scale",
                    basis: "Out of #{agree.count} choices made with AI advice. A person decides every step. #{impact.agreement_flag}".strip,
                    before: nil, after: agree.value, before_text: "not measured", after_text: impact_value(agree.value, "%"),
                    count: agree.count, scale: 100, change: "Now measured", tone: "neutral")
    ]
  end

  # "not entered" is load-bearing: test/integration/impact_test.rb asserts it until the client's
  # figure exists, and the page must never fill the gap with a made-up value.
  # The separator is fixed to "." because the staff screens are in English while the app's I18n
  # locale formats decimals with a comma ("0,2 hours" was seen on the page, 17 Oct 2026).
  def impact_value(value, suffix)
    value.nil? ? "not entered" : "#{number_with_precision(value, precision: 1, strip_insignificant_zeros: true, separator: ".", delimiter: ",")}#{suffix}"
  end

  # Bar width in percent of the row's scale; 0 when either side is missing.
  def impact_bar(value, scale)
    return 0 if value.nil? || scale.nil? || scale.zero?

    [(100.0 * value / scale).round, 100].min
  end

  # The feature page holding the records behind one measure for one vacancy. Who-read figures come
  # from the reviewer's screening review, which only the HR Manager (and the superadmin) may open;
  # everyone else is sent to the screening report, which shows the same participations.
  def impact_source(key, job)
    if %i[read minutes].include?(key) && current_user.role.in?(%w[hr_manager superadmin])
      ["Screening review", staff_job_screening_review_path(job)]
    else
      ["Screening report", staff_job_screening_report_path(job)]
    end
  end

  # Where the BEFORE figures are entered. Settings is superadmin-only and is not drawn on the public
  # demo (config/routes.rb), so the link appears only where it would open.
  def impact_settings_path
    staff_settings_path if current_user.role == "superadmin" && respond_to?(:staff_settings_path)
  end

  private

  def impact_change(before, after, lower_is_better:, unit:)
    return { change: "-", tone: "neutral" } if before.nil? || after.nil?

    diff = after - before
    return { change: "No change", tone: "neutral" } if diff.zero?

    better = lower_is_better ? diff.negative? : diff.positive?
    sign = diff.positive? ? "+" : "-"
    text = case unit
           # A zero BEFORE has no meaningful percentage; fall back to the raw difference in hours.
           when :percent then before.zero? ? "#{sign}#{impact_value(diff.abs, " hours")}" : "#{(100.0 * diff.abs / before).round}% #{better ? "faster" : "slower"}"
           when :points then "#{sign}#{diff.abs.round} pts"
           when :minutes then "#{sign}#{impact_value(diff.abs, " min")}"
           end
    { change: text, tone: better ? "good" : "bad" }
  end
end
