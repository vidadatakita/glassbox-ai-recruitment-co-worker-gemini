require "test_helper"

class Stages::CloseTest < ActiveSupport::TestCase
  setup { @stage = Stages::Open.call(stage: create_stage) }

  test "refuses to close while a participation has no decision, and names it" do
    waiting = create_participation(stage: @stage)
    error = assert_raises(Stages::Close::Undecided) { Stages::Close.call(stage: @stage) }
    assert_includes error.message, waiting.job_application_id.to_s
    assert_equal "open", @stage.reload.status
  end

  test "a decision still in review does not count as decided" do
    p = create_participation(stage: @stage)
    add_score(p, 55)
    decide!(p, outcome: "review", reason_code: "below_threshold_review")
    assert_raises(Stages::Close::Undecided) { Stages::Close.call(stage: @stage) }
  end

  test "closes when every participation is decided" do
    p = create_participation(stage: @stage)
    add_score(p, 80)
    decide!(p, outcome: "pass")
    assert_equal "closed", Stages::Close.call(stage: @stage).status
  end
end
