require "test_helper"

# The draw is stratified (every activity or competency before any twice) and random per applicant;
# an unsubmitted draft is deleted once the portal is closed, a submitted one is kept.
class ApplicationDrafts::DrawAndPurgeTest < ActiveSupport::TestCase
  setup do
    @job = briefed_job(golongan: 3, package: 3, complete: false, test_case: false)
    @admin = staff_user("hr_pic")
    acts = @job.activities.first(3)
    comp = @job.competencies.first
    add = ->(params) { assert TestCases::SaveBank.call(job: @job, actor: @admin, action: "add", params:).ok? }
    # 8 questions on activity 1, 1 each on activities 2 and 3: a plain random pick would usually miss 2 or 3.
    8.times { |i| add.call(section: "technical", kind: "multiple_choice", link_id: "a:#{acts[0].id}", prompt: "A1 #{i}", options: { "0" => "x", "1" => "y" }, correct: "0") }
    [acts[1], acts[2]].each { |a| add.call(section: "technical", kind: "multiple_choice", link_id: "a:#{a.id}", prompt: "Other #{a.id}", options: { "0" => "x", "1" => "y" }, correct: "0") }
    6.times { |i| add.call(section: "role", kind: "multiple_choice", link_id: "c:#{comp.id}", prompt: "R #{i}", options: { "0" => "x", "1" => "y" }, correct: "0") }
    @bank = QuestionBank.latest_for(@job)
  end

  test "every activity is drawn before any is drawn twice, whatever the random seed" do
    activity_ids = @job.activities.first(3).map(&:id)
    20.times do |seed|
      ids = ApplicationDrafts::Draw.call(@bank, random: Random.new(seed))
      technical = BankQuestion.where(id: ids, section: "technical")
      assert_equal 5, technical.count
      assert_equal activity_ids.sort, technical.map(&:activity_id).uniq.sort, "seed #{seed} skipped an activity"
      assert_equal 3, BankQuestion.where(id: ids, section: "role").count
    end
    refute_equal ApplicationDrafts::Draw.call(@bank, random: Random.new(1)), ApplicationDrafts::Draw.call(@bank, random: Random.new(2)),
                 "two applicants do not get the same set (control on the randomness)"
  end

  test "purge deletes unsubmitted drafts of a closed portal only" do
    consent = publish_consent
    open_draft = ApplicationDraft.open!(job: @job, consent_template: consent, consent_retention_days: 30, consent_at: Time.current,
                                         question_bank: @bank, time_limit_minutes: 30).first
    window = Struct.new(:open) { def open? = open }
    ApplicationWindow.stub(:new, window.new(true)) { assert_equal 0, ApplicationDrafts::Purge.call }
    assert ApplicationDraft.exists?(open_draft.id)
    ApplicationWindow.stub(:new, window.new(false)) { assert_equal 1, ApplicationDrafts::Purge.call }
    refute ApplicationDraft.exists?(open_draft.id)
  end
end
