require "test_helper"

class AppConfigTest < ActiveSupport::TestCase
  test "times display in WIB and are stored in UTC" do
    assert_equal "Asia/Jakarta", Rails.application.config.time_zone
    assert_equal :utc, ActiveRecord.default_timezone
  end

  test "schema is dumped as SQL so the append-only triggers survive db:schema:load" do
    assert_equal :sql, Rails.application.config.active_record.schema_format
  end
end
