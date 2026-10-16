require "test_helper"
require Rails.root.join("db/seeds/demo_glassbox").to_s

# End-to-end test of 16 Oct 2026, P0. Runs db/seeds.rb itself, as Demo::Reset does after reloading
# the schema, with no AI_MODEL_* / AI_THINKING_* set. Nothing reaches the AI: the seed switches it
# off while it runs. Risk hunted: opening a vacancy's portal locks the tier -> model mapping in force
# on it (FLOW §9 rule 2), and the seed opens the three demo vacancies. It locked gemini-3.8-pro, an
# id Vertex AI does not serve, so every application to the public demo ended in "Screening failed"
# until the next reset.
class CupDemoSeedTest < ActiveSupport::TestCase
  AI_SETTINGS = %w[AI_MODEL AI_THINKING AI_MODEL_HIGH AI_MODEL_MEDIUM AI_MODEL_LOW
                   AI_THINKING_HIGH AI_THINKING_MEDIUM AI_THINKING_LOW].freeze

  # Returns the tier mapping in force while the seed ran.
  def seed!
    with_env(AI_SETTINGS.index_with(nil).merge("DEMO_MODE" => "1", "LEGACY_DEMO_SEEDS" => nil)) do
      capture_io { Rails.application.load_seed }
      Screening::Config.tiers_snapshot
    end
  end

  # The seed puts these two back itself; restored here too in case it raises half-way.
  setup { @saved = %i[enabled? review_before_ai?].to_h { |name| [name, Screening::Config.method(name)] } }
  teardown { @saved.each { |name, original| Screening::Config.singleton_class.define_method(name, original) } }

  test "the seeded demo vacancies lock the tier defaults, HIGH on gemini-3.8-flash at thinking medium" do
    in_force = seed!
    jobs = Job.where(title: DemoGlassbox::JOBS.values.pluck(:title)).order(:id).to_a
    assert_equal 3, jobs.size, "the three demo vacancies"
    jobs.each do |job|
      assert_equal({ "model" => "gemini-3.8-flash", "thinking" => "medium" }, job.ai_model_tiers["high"], "#{job.title}: HIGH tier")
      assert_equal in_force, job.ai_model_tiers, "#{job.title}: the mapping in force when the seed ran"
      job.ai_model_tiers.each do |tier, lock|
        assert_includes Screening::Config::KNOWN_MODELS, lock["model"], "#{job.title}: tier #{tier} locked an unknown model id"
      end
    end
  end
end
