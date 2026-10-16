require "test_helper"

# D60: a candidate continues only if BOTH decisions are pass.
class Gates::ResultTest < ActiveSupport::TestCase
  D = Data.define(:outcome)

  test "both pass is the only way through" do
    assert_equal :passed, Gates::Result.of(D.new("pass"), D.new("pass"))
  end

  test "either elimination fails the gate, whatever the other says" do
    assert_equal :not_passed, Gates::Result.of(D.new("eliminate"), nil)
    assert_equal :not_passed, Gates::Result.of(D.new("pass"), D.new("eliminate"))
    assert_equal :not_passed, Gates::Result.of(D.new("eliminate"), D.new("pass"))
    assert_equal :not_passed, Gates::Result.of(D.new("review"), D.new("eliminate"))
  end

  test "anything undecided or in review keeps the gate open" do
    assert_equal :open, Gates::Result.of(nil, nil)
    assert_equal :open, Gates::Result.of(D.new("pass"), nil)
    assert_equal :open, Gates::Result.of(D.new("pass"), D.new("review"))
    assert_equal :open, Gates::Result.of(nil, D.new("pass"))
  end
end
