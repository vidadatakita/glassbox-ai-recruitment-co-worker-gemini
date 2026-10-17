require "test_helper"

# Independent test pass, posting flow of 17 Oct 2026: Write the ad -> Open the applicant portal -> Close or
# reopen. The separate "Approve job ad" step is gone; Portal::WindowChange#open! stamps the approval
# (ad_approved_at / ad_approved_by_id) under the opener, and Briefs::SaveAd asks the writer's reason
# for a rule-flagged sentence on a draft ad too.
#
# Who may open is Portal::WindowChange::ROLES (run 2, three roles: hr_admin and superadmin). staff_user
# maps the old role names to the new ones, so "consultant" below is a second hr_admin person.
#
# Mutant -> the test here that goes red (each was run by hand against the service, see the report):
#   drop `return if @job.ad_approved_at.present?` in approve_ad!  -> "a legacy approval keeps its approver ..."
#   stamp an HR id instead of the opener                         -> "a consultant who opens a written draft ..."
#   skip JobBriefChange.create! in approve_ad!                   -> "a consultant who opens a written draft ..."
#   remove the ad-text precondition                              -> "no written ad and no legacy approval ..."
#   restore `live &&` on the SaveAd reason gate                  -> "a draft rule-flagged save records ..."
#   accept a whitespace-only reason (no squish)                  -> "a whitespace-only reason is no reason ..."
class CupPostingFlowServiceTest < ActiveSupport::TestCase
  RULE_TEXT = "About this role\nFemale, max 28 years old.".freeze
  CLEAN_TEXT = "About this role\nWe need a warehouse administrator in Bekasi.".freeze
  StoreDown = Class.new(StandardError) # an invented infrastructure failure

  setup do
    set_retention
    publish_consent(at: 2.days.ago)
    @hr = staff_user("hr_pic")
    @consultant = staff_user("consultant")
  end

  # A complete brief with a written, never-approved ad: the state the new flow opens from.
  def draft_job(text: CLEAN_TEXT, complete: true)
    job = briefed_job(complete:, ad: false)
    job.update_columns(ad_text: text, ad_flags: Briefs::AdCheck.rule_flags(text.to_s), ad_approved_at: nil, ad_approved_by_id: nil)
    job.reload
  end

  def refused(&block) = assert_raises(Portal::WindowChange::Refused, &block).message

  def approval_rows(job) = job.brief_changes.reload.where(step: "ad").select { |c| c.changes_made.key?("ad_approved_at") }

  def assert_untouched(job)
    job.reload
    assert_nil job.ad_approved_at, "the ad was stamped approved by an open that did not happen"
    assert_nil job.ad_approved_by_id
    assert_empty approval_rows(job), "a history row records an approval that did not happen"
    assert_equal :never_opened, ApplicationWindow.new(job).state
  end

  # --- 1. Can an ad reach applicants without a named person? -------------------------------------

  test "a consultant who opens a written draft is the named approver, recorded once in the brief history" do
    job = draft_job
    event = Portal::WindowChange.open!(job:, actor: @consultant)
    job.reload
    assert_equal @consultant.id, job.ad_approved_by_id, "the approver must be the person who opened, not an HR default"
    assert_equal event.created_at.to_i, job.ad_approved_at.to_i
    rows = approval_rows(job)
    assert_equal 1, rows.size, "exactly one history row for the approval"
    # Run 2 (three roles, 17 Oct): the former consultant is an hr_admin; the person check is unchanged.
    assert_equal [@consultant.id, "hr_admin"], [rows.first.actor_id, rows.first.actor_role]
  end

  test "a legacy approval keeps its approver and its time when someone else opens the portal" do
    job = portal_job # approved by the HR PIC before the ad had a text
    approved_at = job.ad_approved_at
    Portal::WindowChange.open!(job:, actor: @consultant)
    job.reload
    assert_equal @hr.id, job.ad_approved_by_id, "an existing approval must not be overwritten by the opener"
    assert_equal approved_at.to_i, job.ad_approved_at.to_i
    assert_empty approval_rows(job), "no second approval row for an ad that was already approved"
  end

  test "close and reopen by another person never move the approval and write no second history row" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @hr)
    approved_at = job.reload.ad_approved_at
    Portal::WindowChange.close!(job:, actor: @consultant)
    Portal::WindowChange.reopen!(job:, actor: @consultant, reason: "Too few applicants")
    job.reload
    assert ApplicationWindow.new(job).open?
    assert_equal [@hr.id, approved_at.to_i], [job.ad_approved_by_id, job.ad_approved_at.to_i]
    assert_equal 1, approval_rows(job).size
  end

  test "a role outside the opener list cannot open, and the ad stays unapproved" do
    job = draft_job
    # Run 2 (three roles): reviewer and owner are both hr_manager now; "admin" became superadmin, which
    # passes every check, so it moved to the role matrix (posting_flow_roles_test.rb).
    %w[reviewer owner].each do |role|
      assert_match(/Only the HR Admin can open the portal/, refused { Portal::WindowChange.open!(job:, actor: staff_user(role)) }, role)
    end
    assert_untouched(job)
  end

  test "no written ad and no legacy approval: the portal does not open and nothing is stamped" do
    [nil, "", "   \n  "].each do |text|
      job = draft_job(text:)
      assert_match(/job ad has not been written yet/, refused { Portal::WindowChange.open!(job:, actor: @hr) }, text.inspect)
      assert_untouched(job)
    end
  end

  # Invariant: an open window always has a named approver. The state below (an earlier open event
  # but no approval) cannot be produced by the current services; it is planted to pin the reopen path.
  test "reopen never shows an ad that has no named approver" do
    job = draft_job
    ApplicationWindowEvent.create!(job:, action: "open", actor_id: @hr.id, actor_role: "hr_pic", created_at: 2.hours.ago)
    ApplicationWindowEvent.create!(job:, action: "close", actor_id: @hr.id, actor_role: "hr_pic", created_at: 1.hour.ago)
    begin
      Portal::WindowChange.reopen!(job:, actor: @consultant, reason: "Reopen for more applicants")
    rescue Portal::WindowChange::Refused
      return assert_not ApplicationWindow.new(job).open?
    end
    assert_not_nil job.reload.ad_approved_by_id, "the portal reopened and shows an ad nobody approved"
  end

  test "an incomplete brief does not let the portal open, even with a written ad" do
    job = draft_job(complete: false)
    assert_not job.brief_complete?
    message = assert_raises(Portal::WindowChange::Refused, "the server opened a portal on an incomplete brief (the screen hides the button, the service does not refuse)") do
      Portal::WindowChange.open!(job:, actor: @hr)
    end.message
    assert_match(/brief/i, message)
    assert_untouched(job)
  end

  # --- 2. Can a rule-flagged sentence go live without a reason? -----------------------------------

  test "a whitespace-only reason is no reason, on a draft and on a live ad" do
    job = draft_job(text: nil)
    result = Briefs::SaveAd.call(job:, actor: @hr, text: RULE_TEXT, reason: "  \n\t ")
    assert_not result.ok?
    assert result.needs_reason
    assert_nil job.reload.ad_text

    live = draft_job
    Portal::WindowChange.open!(job: live, actor: @hr)
    result = Briefs::SaveAd.call(job: live, actor: @hr, text: RULE_TEXT, confirmed: true, reason: "   ")
    assert_not result.ok?
    assert result.needs_reason
    assert_equal CLEAN_TEXT, live.reload.ad_text
  end

  test "a draft rule-flagged save records the writer's reason under the writer's name" do
    job = draft_job(text: nil)
    assert_not Briefs::SaveAd.call(job:, actor: @consultant, text: RULE_TEXT).ok?, "a draft needs the reason too"
    result = Briefs::SaveAd.call(job:, actor: @consultant, text: RULE_TEXT, reason: "Invented: a women's dormitory supervisor role.")
    assert result.ok?
    row = job.brief_changes.where(step: "ad").order(:id).last
    assert_equal [@consultant.id, "hr_admin"], [row.actor_id, row.actor_role] # run 2: consultant -> hr_admin
    assert_equal "Invented: a women's dormitory supervisor role.", row.changes_made.fetch("ad_flags_reason").last
  end

  test "a rule-flagged ad with its reason recorded at save opens (control for the refusal below)" do
    job = draft_job(text: nil)
    assert Briefs::SaveAd.call(job:, actor: @hr, text: RULE_TEXT, reason: "Invented reason.").ok?
    Portal::WindowChange.open!(job:, actor: @hr)
    assert ApplicationWindow.new(job).open?
  end

  # A draft saved before 17 Oct needed no reason (the reason was asked at the approval step, now
  # gone). Opening it must not show the flagged sentence with no reason ever recorded.
  test "a rule-flagged draft with no recorded reason does not go live at portal open" do
    job = draft_job(text: RULE_TEXT)
    assert Briefs::AdCheck.rule_hit?(job.ad_flags)
    assert job.brief_changes.none? { |c| c.changes_made.key?("ad_flags_reason") }
    message = assert_raises(Portal::WindowChange::Refused, "the portal opened and shows a named protected attribute with no reason on record") do
      Portal::WindowChange.open!(job:, actor: @hr)
    end.message
    assert_match(/reason/i, message)
    assert_untouched(job)
  end

  test "re-saving an unchanged rule-flagged draft with a reason records that reason" do
    job = draft_job(text: RULE_TEXT) # saved under the old rule, no reason on record
    result = Briefs::SaveAd.call(job:, actor: @hr, text: RULE_TEXT, reason: "Invented reason typed on the second save.")
    assert result.ok?, "the save reports success"
    reasons = job.brief_changes.reload.filter_map { |c| c.changes_made["ad_flags_reason"]&.last }
    assert_includes reasons, "Invented reason typed on the second save.", "the screen said saved, but the reason HR typed was dropped"
  end

  # Run 2 (three roles): the former consultant is an hr_admin and may edit a live ad; the role outside
  # the editors is now hr_manager (the former reviewer and owner).
  test "a live ad cannot be changed by an hr_manager, and nothing is recorded" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @hr)
    rows = job.brief_changes.count
    result = Briefs::SaveAd.call(job:, actor: staff_user("reviewer"), text: "#{CLEAN_TEXT}\nEdited by an hr_manager.", confirmed: true)
    assert_not result.ok?
    assert_equal CLEAN_TEXT, job.reload.ad_text
    assert_equal rows, job.brief_changes.count
    assert_equal @hr.id, job.ad_approved_by_id
  end

  # --- 3. Dependencies failing mid-open: transactional, or half-approved? -------------------------

  test "a history write failing mid-open leaves the ad unapproved and the portal unopened" do
    job = draft_job
    JobBriefChange.stub(:create!, ->(*, **) { raise StoreDown, "invented: history store down" }) do
      assert_raises(StoreDown) { Portal::WindowChange.open!(job:, actor: @hr) }
    end
    assert_untouched(job)
  end

  test "a window event failing mid-open leaves the ad unapproved" do
    job = draft_job
    ApplicationWindowEvent.stub(:create!, ->(*, **) { raise StoreDown, "invented: event store down" }) do
      assert_raises(StoreDown) { Portal::WindowChange.open!(job:, actor: @hr) }
    end
    assert_untouched(job)
  end

  test "after a failed open, the person whose open succeeds is the named approver" do
    job = draft_job
    JobBriefChange.stub(:create!, ->(*, **) { raise StoreDown, "invented: history store down" }) do
      assert_raises(StoreDown) { Portal::WindowChange.open!(job:, actor: @hr) }
    end
    Portal::WindowChange.open!(job:, actor: @consultant)
    job.reload
    assert_equal @consultant.id, job.ad_approved_by_id, "the ad is stamped under the HR PIC whose open failed"
    assert_equal [@consultant.id], approval_rows(job).map(&:actor_id), "the approval must be recorded once, under the opener"
  end

  # --- Boundaries and repeats ----------------------------------------------------------------------

  test "the automatic closing time must be strictly after now: equal is refused, one second later opens" do
    freeze_time do
      now = Time.current
      job = draft_job
      assert_match(/must be after now/, refused { Portal::WindowChange.open!(job:, actor: @hr, closes_at: now, now:) })
      assert_untouched(job)
      event = Portal::WindowChange.open!(job:, actor: @hr, closes_at: now + 1.second, now:)
      assert_equal (now + 1.second).to_i, event.closes_at.to_i
      assert ApplicationWindow.new(job, now:).open?
      assert_not ApplicationWindow.new(job, now: now + 1.second).open?, "the window is closed at closes_at"
    end
  end

  test "a second open is refused and writes neither a second event nor a second approval row" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @hr)
    assert_match(/opened before/, refused { Portal::WindowChange.open!(job:, actor: @consultant) })
    assert_equal 1, job.application_window_events.count
    assert_equal 1, approval_rows(job).size
    assert_equal @hr.id, job.reload.ad_approved_by_id
  end
end
