require "test_helper"

# FLOW v2.1 §9: every AI task resolves to its tier's model and thinking; the environment overrides per
# tier; a vacancy's locked mapping wins over the environment; an unknown model id stops the boot.
class Screening::ConfigTiersTest < ActiveSupport::TestCase
  include PortalFactory

  test "each task resolves to its tier's default model and thinking" do
    with_env("AI_MODEL" => nil, "AI_THINKING" => nil, "AI_MODEL_HIGH" => nil, "AI_MODEL_MEDIUM" => nil, "AI_MODEL_LOW" => nil) do
      assert_equal ["gemini-3.8-pro", "high"], [Screening::Config.model(:screening), Screening::Config.thinking(:screening)]
      assert_equal ["gemini-3.8-pro", "high"], [Screening::Config.model(:fairness), Screening::Config.thinking(:fairness)]
      assert_equal ["gemini-3.8-flash", "medium"], [Screening::Config.model(:brief), Screening::Config.thinking(:brief)]
      assert_equal ["gemini-3.5-flash-lite", "low"], [Screening::Config.model(:ad), Screening::Config.thinking(:ad)]
      assert_equal :high, Screening::Config.tier(:test_scoring)
      assert_equal "Tier HIGH · gemini-3.8-pro", Screening::Config.tier_label(:screening)
    end
    assert_raises(ArgumentError) { Screening::Config.tier(:no_such_task) }
  end

  test "AI_MODEL_<TIER> and AI_THINKING_<TIER> override one tier; AI_MODEL overrides every tier" do
    with_env("AI_MODEL_HIGH" => "gemini-3.8-flash", "AI_THINKING_HIGH" => "medium", "AI_MODEL_LOW" => nil, "AI_MODEL" => nil) do
      assert_equal ["gemini-3.8-flash", "medium"], [Screening::Config.model(:screening), Screening::Config.thinking(:screening)]
      assert_equal "gemini-3.5-flash-lite", Screening::Config.model(:ad), "control: the other tiers keep their defaults"
    end
    with_env("AI_MODEL" => "gemini-3.5-flash-lite", "AI_MODEL_HIGH" => nil) do
      assert_equal "gemini-3.5-flash-lite", Screening::Config.model(:screening)
    end
  end

  test "opening the portal locks the mapping on the vacancy, and the locked mapping wins over a later change" do
    job = portal_job
    assert_equal({}, job.ai_model_tiers)
    with_env("AI_MODEL_HIGH" => "gemini-3.8-pro") { open_portal(job) }
    job.reload
    assert_equal "gemini-3.8-pro", job.ai_model_tiers.dig("high", "model")
    assert_equal %w[high low medium], job.ai_model_tiers.keys.sort
    with_env("AI_MODEL_HIGH" => "gemini-3.8-flash") do
      assert_equal "gemini-3.8-flash", Screening::Config.model(:screening), "control: the environment changed"
      assert_equal "gemini-3.8-pro", Screening::Config.model(:screening, job:), "the vacancy keeps the model it opened with"
      assert_equal "Tier HIGH · gemini-3.8-pro", Screening::Config.tier_label(:screening, job:)
    end
  end

  test "an unknown model id stops the boot, naming the key; known ids pass" do
    assert Screening::Config.validate_models!({})
    assert Screening::Config.validate_models!("AI_MODEL_LOW" => "gemini-3.8-flash")
    error = assert_raises(Glassbox::Settings::Invalid) { Screening::Config.validate_models!("AI_MODEL_MEDIUM" => "gemini-9-ultra") }
    assert_match(/AI_MODEL_MEDIUM="gemini-9-ultra"/, error.message)
    assert_match(/Known ids: gemini-3.8-pro, gemini-3.8-flash, gemini-3.5-flash-lite/, error.message)
    error = assert_raises(Glassbox::Settings::Invalid) { Screening::Config.validate_models!("AI_MODEL" => "typo-model") }
    assert_match(/AI_MODEL_HIGH="typo-model"/, error.message, "AI_MODEL feeds every tier, so the first tier names it")
  end
end
