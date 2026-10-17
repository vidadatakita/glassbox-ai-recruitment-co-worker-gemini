require "test_helper"

# Independent test pass 2, posting flow under the three roles (GlassBox Team, 17 Oct 2026): superadmin passes
# every check, hr_admin prepares and opens, hr_manager reads. The matrix: open / reopen / close / save a
# draft ad / save (edit) a live ad, for superadmin, hr_admin, hr_manager, a nil role, an unknown role and
# each of the five retired role names. Then the hunts on the run-1 fixes (F1, F2, F6).
#
# Mutant -> the test here that goes red (run by hand, see the report):
#   hr_manager added to Portal::WindowChange::ROLES           -> "hr_manager, a nil role, ... cannot open"
#   drop the complete-brief check in check_preconditions!     -> "an incomplete brief ..." (posting_flow_test.rb)
#   drop raise_unless_ad_reason_recorded!                     -> "a rule-flagged draft with no recorded reason ..."
#   reopen! without approve_ad!                               -> "reopen of an ad with no approver stamps the reopener"
class CupPostingFlowRolesTest < ActiveSupport::TestCase
  RULE_TEXT = "About this role\nFemale, max 28 years old.".freeze
  RULE_TEXT_2 = "About this role\nMale candidates only.".freeze
  CLEAN_TEXT = "About this role\nWe need a warehouse administrator in Bekasi.".freeze
  RETIRED = %w[hr_pic consultant reviewer owner admin].freeze
  Actor = Struct.new(:id, :role) # a person whose role the app does not know; never saved

  setup do
    set_retention
    publish_consent(at: 2.days.ago)
    @super = staff_user("superadmin")
    @admin = staff_user("hr_pic")
    @manager = staff_user("reviewer")
    assert_equal %w[superadmin hr_admin hr_manager], [@super, @admin, @manager].map(&:role), "the factory no longer maps the roles"
  end

  def draft_job(text: CLEAN_TEXT, complete: true)
    job = briefed_job(complete:, ad: false)
    job.update_columns(ad_text: text, ad_flags: Briefs::AdCheck.rule_flags(text.to_s), ad_approved_at: nil, ad_approved_by_id: nil)
    job.reload
  end

  def refused(&block) = assert_raises(Portal::WindowChange::Refused, &block).message
  def approval_rows(job) = job.brief_changes.reload.where(step: "ad").select { |c| c.changes_made.key?("ad_approved_at") }

  def outsiders = [@manager, Actor.new(nil, nil), Actor.new(nil, "visitor"), *RETIRED.map { |r| Actor.new(nil, r) }]

  def opened_then_closed(job)
    Portal::WindowChange.open!(job:, actor: @admin)
    Portal::WindowChange.close!(job:, actor: @admin)
    job.reload
  end

  # --- Open ------------------------------------------------------------------------------------------

  test "superadmin opens and is the named approver, recorded once under its own role" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @super)
    assert_equal @super.id, job.reload.ad_approved_by_id
    assert_equal [[@super.id, "superadmin"]], approval_rows(job).map { |r| [r.actor_id, r.actor_role] }
    assert_equal "superadmin", job.application_window_events.sole.actor_role
  end

  test "hr_admin opens and is the named approver" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @admin)
    assert_equal @admin.id, job.reload.ad_approved_by_id
    assert_equal [@admin.id], approval_rows(job).map(&:actor_id)
  end

  test "hr_manager, a nil role, an unknown role and every retired role name cannot open" do
    job = draft_job
    outsiders.each do |actor|
      assert_match(/Only the HR Admin can open/, refused { Portal::WindowChange.open!(job:, actor:) }, actor.role.inspect)
    end
    job.reload
    assert_nil job.ad_approved_at
    assert_empty job.application_window_events
    assert_empty approval_rows(job)
  end

  # --- Close and reopen ------------------------------------------------------------------------------

  test "superadmin and hr_admin can close and reopen; the approval stays with the first opener" do
    [@super, @admin].each do |actor|
      job = draft_job
      Portal::WindowChange.open!(job:, actor: @admin)
      Portal::WindowChange.close!(job:, actor:)
      Portal::WindowChange.reopen!(job:, actor:, reason: "More applicants needed")
      assert ApplicationWindow.new(job).open?, actor.role
      assert_equal @admin.id, job.reload.ad_approved_by_id, actor.role
      assert_equal 1, approval_rows(job).size, actor.role
    end
  end

  test "hr_manager and every unknown role cannot close or reopen" do
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @admin)
    outsiders.each do |actor|
      assert_match(/Only the HR Admin can close/, refused { Portal::WindowChange.close!(job:, actor:) }, actor.role.inspect)
    end
    assert ApplicationWindow.new(job).open?
    Portal::WindowChange.close!(job:, actor: @admin)
    outsiders.each do |actor|
      assert_match(/Only the HR Admin can open/, refused { Portal::WindowChange.reopen!(job:, actor:, reason: "Try") }, actor.role.inspect)
    end
    assert_not ApplicationWindow.new(job).open?
    assert_equal 2, job.application_window_events.count
  end

  # --- Saving the ad ---------------------------------------------------------------------------------

  test "superadmin and hr_admin save a draft ad; hr_manager and unknown roles cannot" do
    [@super, @admin].each do |actor|
      job = draft_job(text: nil)
      assert Briefs::SaveAd.call(job:, actor:, text: CLEAN_TEXT).ok?, actor.role
      assert_equal [actor.id, actor.role], job.brief_changes.where(step: "ad").order(:id).last.then { |r| [r.actor_id, r.actor_role] }
    end
    job = draft_job(text: nil)
    outsiders.each do |actor|
      assert_not Briefs::SaveAd.call(job:, actor:, text: CLEAN_TEXT).ok?, actor.role.inspect
    end
    assert_nil job.reload.ad_text
    assert_empty job.brief_changes.where(step: "ad")
  end

  test "superadmin and hr_admin edit a live ad and become its approver; hr_manager and unknown roles cannot" do
    [@super, @admin].each do |actor|
      job = draft_job
      Portal::WindowChange.open!(job:, actor: (actor == @super ? @admin : @super))
      assert Briefs::SaveAd.call(job:, actor:, text: "#{CLEAN_TEXT}\nShift work.", confirmed: true).ok?, actor.role
      assert_equal actor.id, job.reload.ad_approved_by_id, "saving a live ad with the tick is its approval (#{actor.role})"
    end
    job = draft_job
    Portal::WindowChange.open!(job:, actor: @admin)
    outsiders.each do |actor|
      assert_not Briefs::SaveAd.call(job:, actor:, text: "#{CLEAN_TEXT}\nEdited.", confirmed: true).ok?, actor.role.inspect
    end
    assert_equal [CLEAN_TEXT, @admin.id], [job.reload.ad_text, job.ad_approved_by_id]
  end

  test "no retired role literal is accepted by the posting-flow checks" do
    assert_equal %w[hr_admin superadmin], Portal::WindowChange::ROLES.sort
    job = draft_job
    RETIRED.each { |role| assert_not job.ad_writable_by?(Actor.new(nil, role)), role }
    assert_not job.ad_writable_by?(nil)
  end

  # --- Hunts on the run-1 fixes ----------------------------------------------------------------------

  test "F2: a reason recorded for one flagged sentence does not carry over to a new flagged sentence" do
    job = draft_job(text: nil)
    assert Briefs::SaveAd.call(job:, actor: @admin, text: RULE_TEXT, reason: "Invented reason for the first text.").ok?
    refusal = Briefs::SaveAd.call(job:, actor: @admin, text: RULE_TEXT_2)
    assert refusal.needs_reason, "a new flagged sentence must ask its own reason"
    assert_equal RULE_TEXT, job.reload.ad_text
    assert Briefs::SaveAd.call(job:, actor: @admin, text: RULE_TEXT_2, reason: "Invented reason for the second text.").ok?
    Portal::WindowChange.open!(job:, actor: @admin)
    assert ApplicationWindow.new(job).open?
  end

  test "F2: a reason on an older text does not cover a newer flagged text saved without one" do
    job = draft_job(text: nil)
    assert Briefs::SaveAd.call(job:, actor: @admin, text: RULE_TEXT, reason: "Invented reason.").ok?
    # A later save of a different flagged text with no reason row of its own (data from before the rule).
    JobBriefChange.create!(job:, actor: @admin, actor_role: "hr_admin", step: "ad", created_at: Time.current,
                           changes_made: { "ad_text" => [RULE_TEXT, RULE_TEXT_2] })
    job.update_columns(ad_text: RULE_TEXT_2, ad_flags: Briefs::AdCheck.rule_flags(RULE_TEXT_2))
    assert_match(/no reason is recorded/, refused { Portal::WindowChange.open!(job:, actor: @admin) })
  end

  test "F2: an ad with only AI flags opens without a reason" do
    job = draft_job
    job.update_columns(ad_flags: [{ "quote" => "We need a warehouse administrator in Bekasi.", "reason" => "Invented AI reading.", "source" => "ai" }])
    Portal::WindowChange.open!(job:, actor: @admin)
    assert ApplicationWindow.new(job).open?
  end

  # The open checks the flags STORED with the ad. The rule table gained its English rows on 16 Oct 2026, so
  # an English ad saved before that carries no rule flag although its text names a protected attribute.
  test "F2: a flagged text whose stored flags are empty still needs a reason before it goes live" do
    job = draft_job
    job.update_columns(ad_text: RULE_TEXT, ad_flags: [])
    assert Briefs::AdCheck.rule_hit?(Briefs::AdCheck.rule_flags(job.ad_text)), "the text names a protected attribute"
    message = assert_raises(Portal::WindowChange::Refused, "the portal opened on a flagged text because the stored flags were stale") do
      Portal::WindowChange.open!(job:, actor: @admin)
    end.message
    assert_match(/reason/, message)
  end

  test "F1: an edit that would make a complete brief incomplete is refused, so the open still sees a complete brief" do
    job = draft_job
    params = with_requirement_ids(job, step3_params(weights: [50, 40]))
    result = Briefs::SaveStep.call(job:, step: "3", params:, actor: @admin)
    assert_not result.ok?, "a complete brief accepted an edit that breaks it"
    assert job.reload.brief_complete?
    Portal::WindowChange.open!(job:, actor: @admin)
    assert ApplicationWindow.new(job).open?
  end

  test "reopen of a legacy ad keeps its old approver and writes no approval row" do
    job = portal_job # approved by the HR PIC before the ad had a text
    approver = job.ad_approved_by_id
    opened_then_closed(job)
    Portal::WindowChange.reopen!(job:, actor: @super, reason: "Reopen the legacy vacancy")
    assert ApplicationWindow.new(job).open?
    assert_equal approver, job.reload.ad_approved_by_id
    assert_empty approval_rows(job)
  end

  test "reopen of an ad with no approver stamps the reopener, once" do
    job = draft_job
    ApplicationWindowEvent.create!(job:, action: "open", actor_id: @admin.id, actor_role: "hr_admin", created_at: 2.hours.ago)
    ApplicationWindowEvent.create!(job:, action: "close", actor_id: @admin.id, actor_role: "hr_admin", created_at: 1.hour.ago)
    Portal::WindowChange.reopen!(job:, actor: @super, reason: "Reopen for more applicants")
    assert_equal @super.id, job.reload.ad_approved_by_id
    assert_equal [@super.id], approval_rows(job).map(&:actor_id)
  end

  test "a reopen whose event fails leaves the approver-less ad unstamped" do
    job = draft_job
    ApplicationWindowEvent.create!(job:, action: "open", actor_id: @admin.id, actor_role: "hr_admin", created_at: 2.hours.ago)
    ApplicationWindowEvent.create!(job:, action: "close", actor_id: @admin.id, actor_role: "hr_admin", created_at: 1.hour.ago)
    boom = Class.new(StandardError)
    ApplicationWindowEvent.stub(:create!, ->(*, **) { raise boom, "invented: event store down" }) do
      assert_raises(boom) { Portal::WindowChange.reopen!(job:, actor: @super, reason: "Reopen") }
    end
    assert_nil job.reload.ad_approved_at
    assert_empty approval_rows(job)
    assert_not ApplicationWindow.new(job).open?
  end

  test "after a failed open the stale in-memory stamp is not trusted: the retrying opener becomes approver" do
    job = draft_job
    boom = Class.new(StandardError)
    JobBriefChange.stub(:create!, ->(*, **) { raise boom, "invented: history store down" }) do
      assert_raises(boom) { Portal::WindowChange.open!(job:, actor: @admin) }
    end
    assert_not_nil job.ad_approved_at, "precondition: the same in-memory record still carries the rolled-back stamp"
    Portal::WindowChange.open!(job:, actor: @super) # the same object, not reloaded
    assert_equal @super.id, job.reload.ad_approved_by_id
    assert_equal [@super.id], approval_rows(job).map(&:actor_id)
    assert_equal 1, job.application_window_events.count
  end
end
