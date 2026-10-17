# The next step of one vacancy on the vacancy list, and whose move it is: one owner of the rule, read
# by the list's "Next step" column and by its filter (status, next-action owner). Labels are the list's
# own words (test/integration/vacancy_list_next_step_test.rb pins them).
#
# owner: :hr_admin, :hr_manager, :both (the selection mixes HR Admin and HR Manager steps), :nobody.
# status: :brief_draft, :not_opened, :open, :closed, :filled (portal closed and every place filled,
# HeadcountProgress's count).
class VacancyNextStep
  Step = Data.define(:label, :owner, :status, :done)

  def self.for(job, window)
    filled = job.brief_complete? && window.state != :never_opened && HeadcountProgress.new(job).complete?
    if !job.brief_complete? then Step.new("Complete the brief", :hr_admin, :brief_draft, false)
    elsif job.ad_text.blank? then Step.new("Write the job ad", :hr_admin, :not_opened, false)
    elsif window.state == :never_opened then Step.new("Open the Applicant portal", :hr_admin, :not_opened, false)
    elsif window.open? && filled then Step.new("All places filled: close the portal", :hr_admin, :open, false)
    elsif window.open? then Step.new("Watch incoming applications", :hr_admin, :open, false)
    elsif filled then Step.new("Done: all places filled", :nobody, :filled, true)
    else Step.new("Continue the selection", :both, :closed, false)
    end
  end
end
