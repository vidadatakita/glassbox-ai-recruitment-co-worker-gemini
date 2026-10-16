require "test_helper"

# ONP-2, D34: boot refuses a missing or invalid required setting, naming the key; and no setting
# is read from ENV anywhere without being declared in the registry.
class SettingsRegistryTest < ActiveSupport::TestCase
  test "a missing TENANCY is refused with the key's name" do
    error = assert_raises(Glassbox::Settings::Invalid) { Glassbox::Settings.validate!({}) }
    assert_match(/TENANCY is required/, error.message)
  end

  test "an invalid TENANCY is refused with the expected values" do
    error = assert_raises(Glassbox::Settings::Invalid) { Glassbox::Settings.validate!("TENANCY" => "both") }
    assert_match(/TENANCY="both" is invalid; expected single or multi/, error.message)
  end

  test "single and multi are accepted" do
    assert Glassbox::Settings.validate!("TENANCY" => "single")
    assert Glassbox::Settings.validate!("TENANCY" => "multi")
  end

  test "every ENV key read in app/, config/ and lib/ is declared in the registry" do
    files = Dir[Rails.root.join("{app,config,lib}/**/*.{rb,yml,erb}")]
    assert_operator files.size, :>, 50, "the scan read too few files; the glob is wrong"
    used = files.flat_map do |file|
      # Comment lines are skipped: the generator's database.yml shows example keys in comments.
      code = File.readlines(file).reject { |line| line.lstrip.start_with?("#") }.join
      code.scan(/ENV(?:\.fetch\(|\[)\s*"([A-Z0-9_]+)"/).flatten
    end.uniq
    assert_includes used, "TENANCY", "the scan must at least find the TENANCY read; otherwise it reads nothing"
    undeclared = used - Glassbox::Settings::ENV_KEYS.keys
    assert_empty undeclared, "declare these in lib/glassbox/settings.rb: #{undeclared.join(', ')}"
  end

  test "the retention period has no default (D32)" do
    assert_nil Glassbox::Settings::SCREEN_KEYS.fetch("retention_days")[:default]
    assert_nil SystemSetting.retention_days
  end
end
