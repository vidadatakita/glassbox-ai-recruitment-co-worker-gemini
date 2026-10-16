# What one wizard step shows in its fields: the values just submitted when a save was refused
# (an operator never loses what they typed, app-layout-design L3), otherwise the saved brief.
# Repeating sections are padded to a fixed number of slots, because the form has no JavaScript
# row-adder; an empty slot is ignored on save (Briefs::SaveStep#save_rows).
class BriefForm
  ACTIVITY_SLOTS = 8 # the §2.1 maximum
  # Blank slots shown beyond the filled rows, so a long section does not open as a wall of empty
  # fields (screenshot review 2026-10-10: ten competency slots made step 4 5,800 px tall). Each
  # save re-renders with this many fresh blank slots, up to the section maximum.
  SPARE_SLOTS = 2
  MIN_SLOTS = { "activities" => 5, "wajib" => 3, "sebaiknya" => 3, "nilai_tambah" => 2, "competencies" => 4 }.freeze
  # Slot counts per tier are a screen limit, not a rule: the spec sets no maximum. Each tier owns a
  # fixed index range so the rows come back in tier order (wajib first, as BriefCheck reads them).
  REQUIREMENT_SLOTS = { "wajib" => 0...6, "sebaiknya" => 6...12, "nilai_tambah" => 12...16 }.freeze
  COMPETENCY_SLOTS = 10
  PLACEMENT_SLOTS = 5

  attr_reader :job, :step

  def initialize(job, step, submitted: nil)
    @job = job
    @step = step
    @submitted = submitted&.deep_stringify_keys
  end

  def submitted? = !@submitted.nil?

  def value(field) = submitted? ? @submitted[field] : job.public_send(field)

  def checked?(field) = ActiveModel::Type::Boolean.new.cast(value(field)) || false

  def placements
    list = submitted? ? Array(@submitted["placements"]) : job.placements
    pad(list, PLACEMENT_SLOTS, "")
  end

  def activities
    rows = submitted? ? rows_of("activities") : job.activities.map { |a| a.slice("id", "description", "output", "share_percent") }
    pad(rows, visible("activities", rows, ACTIVITY_SLOTS), {})
  end

  # [[slot index, row], ...] for one tier.
  def requirements(tier)
    rows = submitted? ? rows_of("requirements").select { |r| r["tier"] == tier } : saved_requirements(tier)
    range = REQUIREMENT_SLOTS.fetch(tier)
    range.first(visible(tier, rows, range.size)).zip(pad(rows, visible(tier, rows, range.size), {}))
  end

  def competencies
    rows = submitted? ? rows_of("competencies") : job.competencies.map { |c| c.slice(*%w[id name layer stage_code anchor_1 anchor_3 anchor_5 questions]) }
    pad(rows, visible("competencies", rows, COMPETENCY_SLOTS), {})
  end

  # The package shown as chosen: the typed one, the saved one, or the §7.1 default choice.
  def package
    chosen = submitted? ? @submitted["package"].presence&.to_i : job.package
    chosen || (job.golongan && Briefs::PackageAdvisor.default_choice(job.golongan))
  end

  # Weight and threshold per scored stage code; a missing weight shows the concept-brief default
  # for the chosen package as a prefill, a missing threshold stays blank (no default exists).
  def stage_value(code, field)
    plan = submitted? ? @submitted.fetch("stage_plan", {}) : job.stage_plan
    saved = plan.dig(code, field)
    return saved unless saved.nil? || saved == ""
    return unless field == "weight" && package

    Briefs::StagePlan.default_weights(package)[code]
  end

  # The threshold as it goes back into the field: what was typed after a refused save, otherwise
  # the saved number written the Indonesian way ("60", "62,5"), which Params#decimal_value reads.
  def threshold_field(code)
    value = stage_value(code, "threshold")
    return value.to_s if submitted? || value.nil?

    number = value.to_d
    number == number.truncate ? number.to_i.to_s : number.round(1).to_s("F").tr(".", ",")
  end

  # Knockout questions entered before the form existed (requirement_id nil): shown read-only.
  def legacy_knockouts = job.persisted? ? job.knockout_questions.where(requirement_id: nil).order(:position).to_a : []

  # Cities already used on any job, as typing suggestions. There is no city master table (open
  # item in the feature record), so this is a convenience, not a list of allowed values.
  def city_suggestions = Job.where(client_company_id: job.client_company_id).where.not(placements: []).pluck(:placements).flatten.uniq.sort

  def total(rows, field) = rows.sum { |r| r[field].to_s.match?(/\A\d+\z/) ? r[field].to_i : 0 }

  def sebaiknya_total = total(requirements("sebaiknya").map(&:last), "weight")

  def stage_total = package ? Briefs::StagePlan.scored_codes(package).sum { |c| stage_value(c, "weight").to_s.to_i } : 0

  private

  # The submitted rows that carry something, in slot order; blank slots are re-padded on display.
  def rows_of(key)
    value = @submitted[key]
    value = value.sort_by { |k, _| k.to_i }.map(&:last) if value.is_a?(Hash)
    Array(value).select { |r| r.is_a?(Hash) && filled?(r) }
  end

  def filled?(row) = row.except("id", "tier").values.any? { |v| v.to_s.strip.present? }

  def saved_requirements(tier)
    job.requirements.select { |r| r.tier == tier }.map do |r|
      r.slice("id", "tier", "text", "cv_evidence", "weight").merge("knockout" => r.knockout_question&.text)
    end
  end

  # Filled rows plus SPARE_SLOTS blanks, at least the section minimum, at most its maximum. A
  # submitted slot list keeps its blanks, so only the non-blank rows count as filled.
  def visible(section, rows, max)
    (rows.count { |r| filled?(r) } + SPARE_SLOTS).clamp(MIN_SLOTS.fetch(section), max)
  end

  def pad(list, size, filler) = list.first(size) + Array.new([size - list.size, 0].max) { filler.dup }
end
