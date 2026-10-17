require "test_helper"

# BP §3.6 A; D32 (no retention, no portal); process card 4 (approved ad); roles from §1.2.
class Portal::WindowChangeTest < ActiveSupport::TestCase
  setup do
    @job = portal_job
    @hr = staff_user("hr_pic")
  end

  def refused(&block)
    assert_raises(Portal::WindowChange::Refused, &block).message
  end

  test "refused while the retention period is unset, and says why" do
    publish_consent
    message = refused { Portal::WindowChange.open!(job: @job, actor: @hr) }
    assert_match(/retention period has not been set/, message)
    assert_equal :never_opened, ApplicationWindow.new(@job).state
  end

  test "refused without a consent text in force" do
    set_retention
    assert_match(/consent text/, refused { Portal::WindowChange.open!(job: @job, actor: @hr) })
  end

  test "refused while the ad has no text; a written ad opens and is approved by the opener" do
    set_retention
    publish_consent
    @job.update!(ad_approved_at: nil, ad_text: nil)
    assert_match(/job ad has not been written yet/, refused { Portal::WindowChange.open!(job: @job, actor: @hr) })
    @job.update!(ad_text: "About this role\nInvented ad.")
    Portal::WindowChange.open!(job: @job, actor: @hr)
    assert_equal @hr.id, @job.reload.ad_approved_by_id
  end

  # Three-role model (17 Oct 2026): the old consultant is an HR admin, so the event logs "hr_admin";
  # the old reviewer is an HR manager, who still may not open the portal.
  test "an HR admin other than the ad's approver may open and the role is logged; an HR manager may not" do
    set_retention
    publish_consent
    assert_match(/Only the HR Admin/, refused { Portal::WindowChange.open!(job: @job, actor: staff_user("reviewer")) })
    event = Portal::WindowChange.open!(job: @job, actor: staff_user("consultant"))
    assert_equal "hr_admin", event.actor_role
  end

  test "reopen needs a reason, and the database refuses a blank one too" do
    open_portal(@job)
    Portal::WindowChange.close!(job: @job, actor: @hr)
    assert_match(/reason is required/, refused { Portal::WindowChange.reopen!(job: @job, actor: @hr, reason: " ") })
    error = refused_by_database do
      ApplicationWindowEvent.new(job: @job, action: "reopen", reason: " ", actor_id: @hr.id, actor_role: "hr_pic",
                                 created_at: Time.current).save!(validate: false)
    end
    assert_match(/window_events_reopen_reason/, error.message)
    Portal::WindowChange.reopen!(job: @job, actor: @hr, reason: "Kandidat kurang")
    assert ApplicationWindow.new(@job).open?
  end

  test "window events are append-only in the database" do
    event = open_portal(@job)
    assert_match(/append-only/, refused_by_database { ApplicationWindowEvent.where(id: event.id).update_all(action: "close") }.message)
    assert_match(/append-only/, refused_by_database { ApplicationWindowEvent.where(id: event.id).delete_all }.message)
    assert_match(/TRUNCATE refused/, refused_by_database { ActiveRecord::Base.connection.execute("TRUNCATE application_window_events CASCADE") }.message)
  end
end
