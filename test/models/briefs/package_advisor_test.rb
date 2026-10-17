require "test_helper"

# Blueprint §7.1 recommended package per Golongan, and process card 3 (override needs a reason).
class Briefs::PackageAdvisorTest < ActiveSupport::TestCase
  SPEC = { 1 => [2, 3], 2 => [2, 3], 3 => [3], 4 => [3], 5 => [3], 6 => [3], 7 => [3], 8 => [3] }.freeze

  test "the recommendation per Golongan matches §7.1" do
    SPEC.each { |golongan, packages| assert_equal packages, Briefs::PackageAdvisor.recommended(golongan), "G#{golongan}" }
  end

  test "a recommended package needs no reason; any other package does" do
    SPEC.each do |golongan, packages|
      packages.each { |p| assert_nil Briefs::PackageAdvisor.override_problem(golongan, p, nil), "G#{golongan} P#{p}" }
      ((1..5).to_a - packages).each do |p|
        assert_match(/Write the reason/, Briefs::PackageAdvisor.override_problem(golongan, p, nil), "G#{golongan} P#{p}")
        assert_match(/Write the reason/, Briefs::PackageAdvisor.override_problem(golongan, p, "   "), "blank reason G#{golongan} P#{p}")
        assert_nil Briefs::PackageAdvisor.override_problem(golongan, p, "Klien meminta seleksi lebih ringan"), "with reason"
      end
    end
  end

  test "every Golongan has a stated reason for its recommendation" do
    (1..8).each { |g| assert Briefs::PackageAdvisor.reason(g).present?, "G#{g}" }
  end
end
