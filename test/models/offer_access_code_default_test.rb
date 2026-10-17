require "test_helper"

# The fixed offer code (OfferAccessCode::DEFAULT_CODE) must open the offer in development and in
# the public demo, and must be refused everywhere else: a code everyone knows in production would
# let any forwarded status link show the salary (D36).
class OfferAccessCodeDefaultTest < ActiveSupport::TestCase
  test "the default code is enabled in development and in demo mode only" do
    assert OfferAccessCode.default_code_enabled?(rails_env: "development", env: {})
    assert OfferAccessCode.default_code_enabled?(rails_env: "production", env: { "DEMO_MODE" => "1" })
    refute OfferAccessCode.default_code_enabled?(rails_env: "production", env: {}), "a production install accepted the default code"
    refute OfferAccessCode.default_code_enabled?(rails_env: "production", env: { "DEMO_MODE" => "0" })
    refute OfferAccessCode.default_code_enabled?(rails_env: "test", env: {})
  end

  test "redeem accepts the default code only while it is enabled" do
    application = JobApplication.first || skip("no job application fixture")
    OfferAccessCode.stub(:default_code_enabled?, true) do
      assert OfferAccessCode.redeem(application, " 123456 ")
      assert OfferAccessCode.redeem(application, "123456"), "the default code works every time, it is not consumed"
    end
    OfferAccessCode.stub(:default_code_enabled?, false) do
      refute OfferAccessCode.redeem(application, "123456"), "the default code opened the offer while disabled"
    end
  end
end
