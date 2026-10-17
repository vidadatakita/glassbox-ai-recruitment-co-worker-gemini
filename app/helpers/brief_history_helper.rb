# The brief change history modal (staff/job_briefs/_history_modal). JobBriefChange#changes_made
# stores each changed field as [before, after]; these helpers only turn those pairs into short,
# readable text. Nothing here changes what is recorded.
module BriefHistoryHelper
  # How many changes the modal lists. Twenty matches the inline table it replaced.
  BRIEF_HISTORY_LIMIT = 20

  def brief_history(job) = job.brief_changes.includes(:actor).order(created_at: :desc, id: :desc).limit(BRIEF_HISTORY_LIMIT).to_a

  # A recorded value is normally [before, after]; anything else is shown as a new value, so an
  # unexpected shape still renders instead of raising on the history page.
  def brief_change_pair(value) = value.is_a?(Array) && value.size == 2 ? value : [nil, value]

  def brief_field_label(key) = t("brief_fields.#{key}", default: key.to_s.humanize)

  # One side of a change. Lists and nested values (requirements, activities, stage plans) can be
  # long, so they are summarised by size instead of dumped; text is cut at 80 characters. The full
  # value stays in the record.
  def brief_change_value(value)
    case value
    when nil, "" then "empty"
    when true then "yes"
    when false then "no"
    when Array then pluralize(value.size, "item")
    when Hash then pluralize(value.size, "field")
    else truncate(value.to_s, length: 80)
    end
  end
end
