require "test_helper"

# The brief change history moved from an inline table to a modal (17 Oct 2026): the page header
# carries a "Change history" button that opens it, and the modal lists the recorded changes newest
# first with each field's before -> after. The record itself (job_brief_changes) is untouched.
class BriefHistoryModalTest < ActionDispatch::IntegrationTest
  include PortalFactory

  setup do
    @job = portal_job
    @hr = staff_user("hr_pic")
    JobBriefChange.create!(job: @job, actor: @hr, actor_role: @hr.role, step: "1", created_at: 2.days.ago,
                           changes_made: { "title" => ["Data Analyst", "Senior Data Analyst"] })
    JobBriefChange.create!(job: @job, actor: @hr, actor_role: @hr.role, step: "3", created_at: 1.hour.ago,
                           changes_made: { "salary_max" => [nil, 12_000_000], "requirements" => [[], [{ "text" => "SQL" }, { "text" => "Excel" }]] })
  end

  test "the header button opens the modal, which lists the changes newest first with before and after" do
    sign_in_as @hr
    get staff_job_brief_path(@job)
    assert_response :success

    assert_select "button[type=button][data-bs-toggle=modal][data-bs-target='#brief-history-modal']", text: /Change history/
    assert_select "#brief-history-modal.modal" do
      assert_select ".brief-history__item", count: 2
      assert_select ".brief-history__item:first-child .brief-history__step", text: "Requirements & compensation"
      assert_select ".brief-history__item:last-child .brief-history__chip--before", text: "Data Analyst"
      assert_select ".brief-history__item:last-child .brief-history__chip--after", text: "Senior Data Analyst"
      assert_select ".brief-history__chip--before", text: "empty"
      assert_select ".brief-history__chip--after", text: "2 items"
    end
    assert_select "form #brief-history-modal", { count: 0 }, "the modal sits outside every form (house hard rule)"
    assert_select ".card-title", { text: /Brief change history/, count: 0 }, "the inline table is gone from the page"
  end

  test "the hr_manager, who cannot edit the brief, still opens the history" do
    sign_in_as staff_user("reviewer")
    get staff_job_brief_path(@job)
    assert_response :success
    assert_select "#brief-history-modal .brief-history__item", count: 2
  end
end
