# The brief page's "AI advice vs saved brief" (AI Builder Cup "knowledge moment"): the latest AI
# proposal (BriefSuggestion) beside the brief as saved, line by line, so it is visible what the AI
# proposed and what the person kept, changed, added or left out. Lines are matched by their text
# (case and spacing ignored); an edited text therefore shows as one AI line not used plus one line
# written by the person, which is what happened.
class BriefSuggestionDiff
  Row = Data.define(:section, :ai, :saved, :status)
  STATUS = {
    kept: ["Same as AI advice", "success"], changed: ["Changed by HR", "warning"],
    added: ["Written by HR", "primary"], dropped: ["AI advice not used", "secondary"]
  }.freeze

  attr_reader :suggestion

  # The latest proposal of each kind: the brief (steps 2-3) and the competency map (step 4).
  def initialize(job)
    @job = job
    proposals = job.brief_suggestions.to_a
    @suggestion = proposals.reverse.find(&:brief?)
    @competency_suggestion = proposals.reverse.find { |s| s.competencies.any? }
  end

  def present? = !(suggestion || @competency_suggestion).nil?

  def rows
    @rows ||= [*brief_rows, *competency_rows]
  end

  def counts = rows.group_by(&:status).transform_values(&:size)

  def requested_by = [suggestion, @competency_suggestion].compact.max_by(&:id).actor

  private

  def brief_rows
    return [] unless suggestion

    [target_row, *lines("Activities", suggestion.activities, saved_activities, "description") { |r| "#{r['output']} · #{r['share_percent']}%" },
     *lines("Requirements", suggestion.requirements, saved_requirements, "text") { |r| [Requirement::TIERS[r["tier"]], r["cv_evidence"], (r["weight"] && "#{r['weight']}%")].compact.join(" · ") }]
  end

  def competency_rows
    return [] unless @competency_suggestion

    saved = @job.competencies.map { |c| c.slice("name", "layer", "stage_code", "anchor_1", "anchor_3", "anchor_5", "questions") }
    lines("Competencies", @competency_suggestion.competencies, saved, "name") do |r|
      [r["layer"], Briefs::StagePlan::LABELS[r["stage_code"]], (r["questions"].present? ? "with questions" : nil)].compact.join(" · ")
    end
  end

  def target_row
    ai = suggestion.success_90d.presence
    saved = @job.success_90d.presence
    status = if ai.nil? then :added
             elsif saved.nil? then :dropped
             elsif key(ai) == key(saved) then :kept
             else :changed
             end
    Row.new("90-day target", ai, saved, status)
  end

  # One row per line: matched by text, then compared on the detail the block returns.
  def lines(section, proposed, saved, field, &detail)
    left = saved.dup
    rows = proposed.map do |ai|
      match = left.find { |s| key(s[field]) == key(ai[field]) && s["tier"] == ai["tier"] }
      left.delete(match)
      next Row.new(section, line(ai, field, detail), nil, :dropped) unless match

      Row.new(section, line(ai, field, detail), line(match, field, detail), detail.call(ai) == detail.call(match) ? :kept : :changed)
    end
    rows + left.map { |s| Row.new(section, nil, line(s, field, detail), :added) }
  end

  def line(row, field, detail) = "#{row[field]} (#{detail.call(row)})"

  def saved_activities = @job.activities.map { |a| a.slice("description", "output", "share_percent") }

  def saved_requirements = @job.requirements.map { |r| r.slice("tier", "text", "cv_evidence", "weight") }

  def key(text) = text.to_s.downcase.gsub(/[[:space:]]+/, " ").strip
end
