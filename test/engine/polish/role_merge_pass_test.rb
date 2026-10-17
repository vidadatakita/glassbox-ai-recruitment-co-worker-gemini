require "test_helper"

# Independent test pass (17 Oct 2026): the three role-merge blind-screening suspects, verified on the
# CURRENT code. A note recorded earlier that three predicates had two identical arms after the role
# rename (consultant+hr_pic -> hr_admin, reviewer+owner -> hr_manager, admin -> superadmin):
#   ScreeningReport::Visibility#contacts?, TechnicalTests.answer_downloadable_by?, Job#ad_writable_by?
# These tests pin the SHAPE that matters, not only a truth table:
#   - no role ever gets contacts while the name is masked (contacts implies names), on a blind and on
#     a confirmed vacancy;
#   - the HR Admin's answer is the only one that depends on confirmation: both case arms are reachable;
#   - writing the ad does not depend on the ad's approval stamp (the comment says "draft or live").
# The confirmation itself (gate closed) is stubbed: CandidateIdentity.screening_confirmed? is pinned by
# test/engine/cup/role_visibility_test.rb on a real seeded closed gate.
class PolishRoleMergePassTest < ActiveSupport::TestCase
  Actor = Struct.new(:id, :role)
  ROLES = %w[superadmin hr_admin hr_manager].freeze
  OTHERS = [nil, "", "visitor", "hr_pic", "consultant", "reviewer", "owner", "admin"].freeze

  def job = @job ||= Job.new(title: "Warehouse Planner", golongan: 2)

  def with_confirmed(value, &)
    CandidateIdentity.stub(:screening_confirmed?, value, &)
  end

  test "no role sees contacts while the name is masked, blind or confirmed" do
    [false, true].each do |confirmed|
      with_confirmed(confirmed) do
        (ROLES + OTHERS).each do |role|
          v = ScreeningReport::Visibility.new(job, Actor.new(1, role))
          assert(!v.contacts? || v.names?, "#{role.inspect} (confirmed=#{confirmed}): contacts while the name is masked")
        end
      end
    end
  end

  test "contacts: the HR Admin's answer depends on confirmation; superadmin always; HR Manager never" do
    answers = [false, true].to_h do |confirmed|
      [confirmed, with_confirmed(confirmed) { ROLES.to_h { |r| [r, ScreeningReport::Visibility.new(job, Actor.new(1, r)).contacts?] } }]
    end
    assert_equal({ "superadmin" => true, "hr_admin" => false, "hr_manager" => false }, answers[false])
    assert_equal({ "superadmin" => true, "hr_admin" => true, "hr_manager" => false }, answers[true])
  end

  test "answer download: both case arms reachable; only the HR Admin waits for confirmation" do
    blind = with_confirmed(false) { ROLES.to_h { |r| [r, TechnicalTests.answer_downloadable_by?(Actor.new(1, r), job)] } }
    open = with_confirmed(true) { ROLES.to_h { |r| [r, TechnicalTests.answer_downloadable_by?(Actor.new(1, r), job)] } }
    assert_equal({ "superadmin" => true, "hr_admin" => false, "hr_manager" => true }, blind)
    assert_equal({ "superadmin" => true, "hr_admin" => true, "hr_manager" => true }, open)
    OTHERS.each do |role|
      with_confirmed(true) { assert_not TechnicalTests.answer_downloadable_by?(Actor.new(1, role), job), role.inspect }
    end
    assert_not TechnicalTests.answer_downloadable_by?(nil, job)
  end

  test "ad writing does not depend on the approval stamp; HR Manager and unknown roles never" do
    draft = Job.new(ad_approved_at: nil)
    live = Job.new(ad_approved_at: Time.current)
    (ROLES + OTHERS).each do |role|
      actor = Actor.new(1, role)
      assert_equal draft.ad_writable_by?(actor), live.ad_writable_by?(actor), "#{role.inspect}: draft and live differ"
    end
    assert_equal %w[superadmin hr_admin], ROLES.select { |r| live.ad_writable_by?(Actor.new(1, r)) }
    assert_not live.ad_writable_by?(nil)
  end

  test "names (CandidateIdentity): superadmin always; HR Admin and HR Manager only once confirmed; others never" do
    application = JobApplication.new(job:)
    [false, true].each do |confirmed|
      with_confirmed(confirmed) do
        assert CandidateIdentity.visible_to?(Actor.new(1, "superadmin"), application)
        %w[hr_admin hr_manager].each do |role|
          assert_equal confirmed, CandidateIdentity.visible_to?(Actor.new(1, role), application), "#{role} confirmed=#{confirmed}"
        end
        OTHERS.each { |role| assert_not CandidateIdentity.visible_to?(Actor.new(1, role), application), role.inspect }
      end
    end
  end
end
