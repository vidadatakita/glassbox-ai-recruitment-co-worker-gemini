require "test_helper"

# Feature 09 (D51 B): the database guards, proven by writing around the services. A model check can
# be bypassed by any code path that inserts a row; these cannot.
class AiReleaseDatabaseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ScreeningFactory

  setup do
    @job = screening_job
    with_ai(FakeGemini.new) do
      @participation = apply_with_cv!(@job)
      perform_enqueued_jobs
    end
    @release = AiRelease.latest_for(@participation)
    @reviewer = staff_user("reviewer")
  end

  def insert_action(release: @release, actor: @reviewer, action: "released", sha: release.payload_sha256, note: nil)
    AiReleaseAction.insert!({ ai_release_id: release.id, action:, actor_id: actor.id, payload_sha256: sha, checked: true,
                              note:, created_at: Time.current })
  end

  test "releases and actions are append-only" do
    refused = ->(&blk) { assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true, &blk) } }
    refused.call { AiRelease.where(id: @release.id).update_all(payload_text: "x") }
    refused.call { AiRelease.where(id: @release.id).delete_all }
    insert_action
    refused.call { AiReleaseAction.where(ai_release_id: @release.id).update_all(action: "declined") }
  end

  test "the stored digest must be the SHA-256 of the stored text" do
    attrs = @release.attributes.except("id").merge("payload_text" => "#{@release.payload_text} ", "created_at" => Time.current)
    assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true) { AiRelease.insert!(attrs) } }
  end

  test "only a reviewer who is not the job's consultant may release; never with a foreign digest" do
    %w[consultant hr_pic owner].each do |role|
      assert_raises(ActiveRecord::StatementInvalid, role) { AiRelease.transaction(requires_new: true) { insert_action(actor: staff_user(role)) } }
    end
    @job.update_columns(consultant_id: @reviewer.id)
    assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true) { insert_action } }
    @job.update_columns(consultant_id: nil)
    assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true) { insert_action(sha: "0" * 64) } }
    insert_action # control: the same insert with the right actor and digest is accepted
    assert_equal "released", @release.reload.action.action
  end

  test "a version with residual findings cannot be released, even written directly" do
    attrs = @release.attributes.except("id").merge("residual_categories" => ["phone"], "created_at" => Time.current)
    id = AiRelease.insert!(attrs).rows.first.first
    leaky = AiRelease.find(id)
    assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true) { insert_action(release: leaky) } }
    insert_action(release: leaky, action: "declined", sha: nil, note: "data pribadi") # declining is allowed
  end

  test "an older version cannot be released once a newer one exists" do
    AiReleases::Cut.call(release: @release, user: @reviewer, line_numbers: [@release.cv_line_end])
    assert_raises(ActiveRecord::StatementInvalid) { AiRelease.transaction(requires_new: true) { insert_action } }
  end
end
