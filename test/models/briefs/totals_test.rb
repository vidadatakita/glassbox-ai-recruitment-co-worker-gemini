require "test_helper"

class Briefs::TotalsTest < ActiveSupport::TestCase
  test "exactly 100 passes; 99 and 101 do not" do
    assert Briefs::Totals.hundred?([60, 40])
    refute Briefs::Totals.hundred?([60, 39])
    refute Briefs::Totals.hundred?([60, 41])
  end

  test "a blank is not read as zero and an empty list is not 100" do
    refute Briefs::Totals.hundred?([100, nil])
    refute Briefs::Totals.hundred?([])
    refute Briefs::Totals.hundred?([50.0, 50.0]), "whole percent only"
    refute Briefs::Totals.hundred?([150, -50]), "no negative share"
  end

  test "thresholds are 0-100 inclusive" do
    assert Briefs::Totals.threshold?(0)
    assert Briefs::Totals.threshold?(100)
    assert Briefs::Totals.threshold?(62.5)
    refute Briefs::Totals.threshold?(100.1)
    refute Briefs::Totals.threshold?(-1)
    refute Briefs::Totals.threshold?(nil)
  end
end
