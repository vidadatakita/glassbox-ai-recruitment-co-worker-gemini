require "test_helper"

# The staff menu marks the section of the page being viewed (a job's own pages count as My vacancies).
class StaffNavTest < ActionDispatch::IntegrationTest
  def active_label = Nokogiri::HTML(response.body).css(".side-menu__item.active .side-menu__label").map(&:text)

  test "each section is active on its own pages, and only it" do
    job = briefed_job
    sign_in_as staff_user("hr_pic")
    { staff_jobs_path => "My vacancies", staff_job_path(job) => "My vacancies", staff_job_brief_path(job) => "My vacancies",
      staff_work_queue_path => "Work queue", staff_impact_path => "Impact summary" }.each do |path, label|
      get path
      assert_equal [label], active_label, path
    end
    assert_equal "page", Nokogiri::HTML(response.body).at_css(".side-menu__item.active")["aria-current"]
  end
end
