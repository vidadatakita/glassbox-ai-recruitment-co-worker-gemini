# Values the step-5 form shows (D60 slice 2): what was typed after a refused save, else the saved
# newest version. A save on an approved or started version makes version n + 1, so the form says
# so and asks for the reason (TestCases::SaveVersion decides the same way on the server).
class TestCaseForm
  SLOTS = TestCases::SaveVersion::CRITERIA_SLOTS

  attr_reader :job, :latest

  def initialize(job, latest, submitted: nil)
    @job = job
    @latest = latest
    @submitted = submitted&.with_indifferent_access
  end

  def mode
    return :first if latest.nil?

    latest.editable? ? :draft : :new_version
  end

  def version_number = mode == :draft ? latest.version : (latest&.version || 0) + 1

  def value(key)
    return @submitted[key].to_s if @submitted&.key?(key)

    case key.to_s
    when "time_limit_minutes" then (latest&.time_limit_minutes || TechnicalTestCase::DEFAULT_TIME_LIMIT).to_s
    when "new_version_reason" then ""
    else latest&.public_send(key).to_s
    end
  end

  def answer_type?(type)
    return Array(@submitted[:answer_types]).include?(type) if @submitted&.key?(:answer_types_submitted)

    Array(latest&.answer_types).include?(type)
  end

  # Filled rows first, then two blank rows (fewer when the slots run out): six empty criteria made
  # the page twice as long as it needed to be (screenshot 2026-10-10). More rows after Save.
  def criteria
    rows = if @submitted
             Briefs::Params.new(@submitted).rows(:criteria).map { |r| r.to_h.stringify_keys }
           else
             Array(latest&.criteria).map { |c| c.slice("activity_id", "name", "weight", "anchor_1", "anchor_3", "anchor_5").transform_values(&:to_s) }
           end
    filled = rows.reject { |r| r.values.all?(&:blank?) }
    filled + Array.new([[SLOTS - filled.size, 2].min, 0].max) { {} }
  end

  def total_weight = criteria.sum { |r| r["weight"].to_s.match?(/\A\d+\z/) ? r["weight"].to_i : 0 }
end
