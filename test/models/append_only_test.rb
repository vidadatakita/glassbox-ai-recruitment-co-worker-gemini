require "test_helper"

# Blueprint §5.1 row 4: the DATABASE refuses edits and deletes, not only the model.
class AppendOnlyTest < ActiveSupport::TestCase
  setup do
    @participation = create_participation(stage: create_open_stage)
    @entry = add_score(@participation, 70)
    @decision = decide!(@participation, outcome: "pass")
  end

  test "the model refuses to update a saved score entry" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @entry.update!(value: 90) }
  end

  test "the database refuses update_all and delete_all on score entries" do
    error = assert_raises(ActiveRecord::StatementInvalid) { ScoreEntry.where(id: @entry.id).update_all(value: 90) }
    assert_match(/append-only/, error.message)
    assert_raises(ActiveRecord::StatementInvalid) { ScoreEntry.where(id: @entry.id).delete_all }
  end

  test "the database refuses raw SQL edits of decisions" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute("UPDATE decisions SET outcome = 'eliminate' WHERE id = #{@decision.id}")
    end
    assert_match(/append-only/, error.message)
  end

  test "the database refuses deleting stage changes" do
    change = StageChange.create!(stage: @participation.stage, field: "threshold", old_value: 65, new_value: 60,
                                 reason: "test", changed_by_id: ScoringFactory::ACTOR_ID, changed_at: Time.current)
    assert_raises(ActiveRecord::StatementInvalid) { StageChange.where(id: change.id).delete_all }
  end
end
