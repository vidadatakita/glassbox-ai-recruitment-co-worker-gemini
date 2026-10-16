require "test_helper"

class Stages::OpenTest < ActiveSupport::TestCase
  test "opening sets the status and opened_at, which locks the stage" do
    stage = Stages::Open.call(stage: create_stage)
    assert_equal "open", stage.status
    assert stage.reload.locked?
  end

  test "only a draft stage can be opened" do
    stage = Stages::Open.call(stage: create_stage)
    assert_raises(ArgumentError) { Stages::Open.call(stage:) }
  end
end
