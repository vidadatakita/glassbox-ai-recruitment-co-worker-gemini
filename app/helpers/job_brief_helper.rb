# Display helpers for the job brief (feature 03). Formatting only; every rule lives in Briefs::*.
module JobBriefHelper
  BRIEF_STATUS = { "draft" => ["Brief draft", "muted"], "complete" => ["Brief complete", "success"] }.freeze

  def brief_status_badge(job)
    label, tone = BRIEF_STATUS.fetch(job.brief_status)
    content_tag(:span, label, class: "portal-state portal-state--#{tone}")
  end

  # One line for a list cell: the first placement and how many more. The full list is shown as a
  # grouped list on the brief page (house view convention: never a comma-joined multi-value).
  def placement_summary(job)
    list = job.placements.presence || [job.location].compact_blank
    return "-" if list.empty?

    list.size == 1 ? list.first : "#{list.first} +#{list.size - 1} more"
  end

  # Thresholds are stored with one decimal; shown the Indonesian way without a trailing ",0".
  def threshold_text(value)
    return "-" if value.nil? || value == ""

    number = value.to_d
    number == number.truncate ? number.to_i.to_s : number.round(1).to_s("F").tr(".", ",")
  end

  def rupiah(amount) = amount ? "Rp#{number_with_delimiter(amount, delimiter: '.')}" : "-"

  def employment_label(job) = Job::EMPLOYMENT_TYPES[job.employment_type] || "-"

  def stage_label(code) = "#{code} #{Briefs::StagePlan::LABELS.fetch(code)}"

  def package_label(package) = package ? "Package #{Briefs::PackageAdvisor.label(package)}" : "-"

  def step_path(job, step) = job.persisted? ? staff_job_brief_step_path(job, step) : nil

  # " is-invalid" (red border) on a required field left empty, but only while the person is
  # checking what blocks completion: after a refused "Simpan & selesaikan brief", or when they come
  # from the list of what is missing (?periksa=1). A draft being typed is not painted red.
  def missing(value) = @checking && value.to_s.strip.empty? ? " is-invalid" : ""

  # The "*" on a label whose field Briefs::BriefCheck needs before the brief can be completed. A
  # draft may still be saved without it; screen readers hear "required".
  def required_mark
    safe_join([content_tag(:span, "*", class: "brief-required", aria: { hidden: true }), content_tag(:span, " (required)", class: "visually-hidden")])
  end
end
